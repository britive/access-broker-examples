# ============================================================
# Cisco IOS XE Account Password Rotation – Multiple Switches
# ============================================================
# Rotates the password for a local user account across a
# group of Cisco Catalyst 9300 (IOS XE) switches via SSH.
# Each switch is processed in sequence. Results are reported
# per-switch; the script exits 1 if any switch fails.
#
# Device connection values are read from CISCO_* first and fall
# back to the resource attributes the broker injects for a
# rotation (RESOURCE_<NAME>, upper-cased):
#   CISCO_SWITCH_HOSTS   / RESOURCE_SWITCH_HOSTS   – comma-separated switch
#                          IPs or hostnames (e.g. "10.0.1.1,10.0.1.2")
#   CISCO_ADMIN_USER     / RESOURCE_ADMIN_USER     – admin username (same on
#                          all switches)
#   CISCO_ADMIN_PASSWORD / RESOURCE_ADMIN_PASSWORD – admin password (same on
#                          all switches)
#   CISCO_ENABLE_SECRET  / RESOURCE_ENABLE_SECRET  – enable secret (optional;
#                          only needed if the admin is not privilege 15)
#
# Required env vars (rotation / permission attributes):
#   CISCO_TARGET_USER     – Existing local username whose password to rotate
#   CISCO_NEW_PASSWORD    – The new password. Supplied by the caller (Britive's
#                           rotation module generates it); never generated
#                           here, because a value Britive did not produce
#                           could not be stored or vended afterwards.
#
# Optional env vars:
#   CISCO_PRIVILEGE_LEVEL     – Privilege level for the target user
#                               (default: 15)
#   CISCO_VERIFY_LOGIN        – "false" to skip the post-rotation login check
#                               (default: true)
#   CISCO_ACCEPT_HOST_KEY     – "true" to accept unknown host keys on first
#                               connect (lab use only; default: false — the
#                               host key must already be trusted via
#                               New-SSHTrustedHost)
#
# Secret rules: whitespace is rejected (IOS reads the secret to end of
# line); '?' is sent behind Ctrl-V so the CLI takes it literally.
# ============================================================

$ErrorActionPreference = 'Stop'

# ─── Helper: open SSH shell, rotate password, save config on one switch ─────

function Invoke-CiscoPasswordRotation {
    param (
        [string]$SwitchHost,
        [string]$AdminUser,
        [SecureString]$AdminPassword,
        [string]$TargetUser,
        [SecureString]$NewPassword,
        [string]$EnableSecret,
        [int]$PrivilegeLevel
    )

    $sshSession = $null

    try {
        Write-Host "  [$SwitchHost] Connecting via SSH..."

        $Credential = New-Object System.Management.Automation.PSCredential($AdminUser, $AdminPassword)

        # ── Host-key policy ─────────────────────────────────────────────────
        # Default: the switch host key must already be trusted by Posh-SSH
        # (New-SSHTrustedHost / Get-SSHTrustedHost). Set
        # CISCO_ACCEPT_HOST_KEY=true to accept unknown keys on first connect
        # (lab use only).
        $hostKeyArgs = @{}
        if ($env:CISCO_ACCEPT_HOST_KEY -and $env:CISCO_ACCEPT_HOST_KEY.ToLower() -eq 'true') {
            $hostKeyArgs['AcceptKey'] = $true
            $hostKeyArgs['Force']     = $true
        }

        $sshSession = New-SSHSession `
            -ComputerName $SwitchHost `
            -Credential $Credential `
            @hostKeyArgs `
            -ErrorAction Stop

        Write-Host "  [$SwitchHost] SSH session established (SessionId: $($sshSession.SessionId))."

        $stream = New-SSHShellStream -SessionId $sshSession.SessionId -ErrorAction Stop

        # ── Poll for the initial exec prompt (> or #) ──────────────────────
        # Posh-SSH's Expect() can return $null if the SSH buffer is empty at
        # the moment the call is made, even when data arrives later within the
        # timeout. Read() in a polling loop is more reliable for the initial
        # banner/prompt that the switch sends after the SSH channel opens.
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $output = ''
        while ([DateTime]::UtcNow -lt $deadline) {
            $chunk = $stream.Read()
            if ($chunk) { $output += $chunk }
            if ($output -match '[>#]\s*$') { break }
            Start-Sleep -Milliseconds 300
        }
        if (-not ($output -match '[>#]\s*$')) {
            throw "Timed out waiting for initial shell prompt."
        }

        # Drain any data that arrived after the first prompt character
        # (remainder of MOTD, terminal negotiation bytes) so the buffer is
        # clean before we start sending commands and calling Expect.
        Start-Sleep -Milliseconds 500
        $stream.Read() | Out-Null

        # ── If in user EXEC mode (>), elevate to privileged EXEC (#) ───────
        if ($output -match '>\s*$') {
            Write-Host "  [$SwitchHost] Entering privileged EXEC mode via 'enable'..."
            $stream.WriteLine("enable")

            $passPrompt = $stream.Expect('Password:', [TimeSpan]::FromSeconds(5))
            if (-not $passPrompt) {
                throw "Timed out waiting for enable password prompt."
            }

            $stream.WriteLine($EnableSecret)

            $privOutput = $stream.Expect('#', [TimeSpan]::FromSeconds(5))
            if (-not $privOutput) {
                throw "Failed to enter privileged EXEC mode. Verify CISCO_ENABLE_SECRET."
            }
            Write-Host "  [$SwitchHost] Privileged EXEC mode entered."
        }

        # ── Pre-flight: rotation only ever changes an existing account ──────
        $stream.WriteLine("terminal length 0")
        $stream.Expect('#', [TimeSpan]::FromSeconds(5)) | Out-Null
        $stream.WriteLine("show running-config | include ^username $TargetUser ")
        $checkOutput = $stream.Expect('#', [TimeSpan]::FromSeconds(15))
        if (-not $checkOutput) {
            throw "Timed out checking whether '$TargetUser' exists on $SwitchHost."
        }
        if ($checkOutput -notmatch "(?m)^username $([regex]::Escape($TargetUser)) ") {
            throw "Local account '$TargetUser' does not exist on $SwitchHost. Rotation never creates accounts."
        }

        # ── Enter global configuration mode ─────────────────────────────────
        Write-Host "  [$SwitchHost] Entering global configuration mode..."
        $stream.WriteLine("configure terminal")
        $configOutput = $stream.Expect('(config)', [TimeSpan]::FromSeconds(10))
        if (-not $configOutput) {
            throw "Failed to enter global configuration mode."
        }

        # ── Rotate the password (scrypt / type-9 hash – IOS XE 16.x+) ──────
        # Decrypt SecureString only at the point of use inside the encrypted SSH session.
        Write-Host "  [$SwitchHost] Setting new password for user: $TargetUser"
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword)
        # PtrToStringBSTR, not PtrToStringAuto: on PowerShell 7 outside Windows,
        # PtrToStringAuto reads the UTF-16 BSTR as UTF-8 and returns only the
        # first character, silently setting a one-character secret.
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        # Ctrl-V (0x16) before '?' makes the IOS CLI take it literally instead of
        # printing context help.
        $cliPassword = $plainPassword.Replace('?', "$([char]0x16)?")
        $stream.WriteLine("username $TargetUser privilege $PrivilegeLevel algorithm-type scrypt secret $cliPassword")
        $setCmdOutput = $stream.Expect('(config)', [TimeSpan]::FromSeconds(10))
        if (-not $setCmdOutput) {
            throw "Timed out waiting for config prompt after setting password."
        }
        if ($setCmdOutput -match '% (Invalid|Incomplete|Ambiguous|Password)') {
            throw "$SwitchHost rejected the new password for '$TargetUser'."
        }

        # ── Exit configuration mode ──────────────────────────────────────────
        $stream.WriteLine("end")
        $endOutput = $stream.Expect('#', [TimeSpan]::FromSeconds(5))
        if (-not $endOutput) {
            throw "Timed out waiting for privileged EXEC prompt after 'end'."
        }

        # ── Persist to NVRAM ─────────────────────────────────────────────────
        Write-Host "  [$SwitchHost] Saving configuration to NVRAM..."
        $stream.WriteLine("write memory")
        $saveOutput = $stream.Expect('Building configuration', [TimeSpan]::FromSeconds(30))
        if (-not $saveOutput) {
            throw "Timed out waiting for 'write memory' to complete."
        }

        # Allow write memory to fully finish before closing the session
        Start-Sleep -Milliseconds 500
        $stream.Read() | Out-Null

        Write-Host "  [$SwitchHost] Configuration saved. Rotation succeeded."
    }
    finally {
        if ($sshSession) {
            Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# ─── Helper: log in as the target account with the new secret ───────────────

function Test-CiscoLogin {
    param (
        [string]$SwitchHost,
        [string]$User,
        [SecureString]$Password
    )

    $session = $null

    try {
        $Credential = New-Object System.Management.Automation.PSCredential($User, $Password)

        $hostKeyArgs = @{}
        if ($env:CISCO_ACCEPT_HOST_KEY -and $env:CISCO_ACCEPT_HOST_KEY.ToLower() -eq 'true') {
            $hostKeyArgs['AcceptKey'] = $true
            $hostKeyArgs['Force']     = $true
        }

        $session = New-SSHSession `
            -ComputerName $SwitchHost `
            -Credential $Credential `
            @hostKeyArgs `
            -ErrorAction Stop
        $stream = New-SSHShellStream -SessionId $session.SessionId -ErrorAction Stop

        # A shell prompt means the switch accepted the account and secret.
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        $output = ''
        while ([DateTime]::UtcNow -lt $deadline) {
            $chunk = $stream.Read()
            if ($chunk) { $output += $chunk }
            if ($output -match '[>#]\s*$') { return $true }
            Start-Sleep -Milliseconds 300
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($session) {
            Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# ─── Main ────────────────────────────────────────────────────────────────────

try {
    # STEP 1: Resolve and validate inputs
    # Device connection values: CISCO_* wins; the RESOURCE_* attributes the
    # broker injects for a rotation (upper-cased attribute names) are the
    # fallback.
    $SwitchHostsRaw = if ($env:CISCO_SWITCH_HOSTS) { $env:CISCO_SWITCH_HOSTS } else { $env:RESOURCE_SWITCH_HOSTS }
    $AdminUser        = if ($env:CISCO_ADMIN_USER)     { $env:CISCO_ADMIN_USER }     else { $env:RESOURCE_ADMIN_USER }
    $AdminPlain       = if ($env:CISCO_ADMIN_PASSWORD) { $env:CISCO_ADMIN_PASSWORD } else { $env:RESOURCE_ADMIN_PASSWORD }
    $EnableSecret     = if ($env:CISCO_ENABLE_SECRET)  { $env:CISCO_ENABLE_SECRET }  else { $env:RESOURCE_ENABLE_SECRET }   # optional
    $TargetUser       = $env:CISCO_TARGET_USER
    $PlainNewPassword = $env:CISCO_NEW_PASSWORD

    if (-not $SwitchHostsRaw)   { throw "CISCO_SWITCH_HOSTS (or resource attribute SWITCH_HOSTS) is not set. Provide a comma-separated list of switch IPs/hostnames." }
    if (-not $AdminUser)        { throw "CISCO_ADMIN_USER (or resource attribute ADMIN_USER) is not set. Cannot authenticate to switches." }
    if (-not $AdminPlain)       { throw "CISCO_ADMIN_PASSWORD (or resource attribute ADMIN_PASSWORD) is not set. Cannot authenticate to switches." }
    if (-not $TargetUser)       { throw "CISCO_TARGET_USER environment variable is not set. Cannot identify target account." }
    # The new password always comes from the caller (the Britive rotation module
    # generates it); a value generated here could not be stored or vended.
    if (-not $PlainNewPassword) { throw "CISCO_NEW_PASSWORD is not set. Supply the new password (the Britive rotation module generates it); this script never generates one." }
    if ($PlainNewPassword -match '\s') { throw "CISCO_NEW_PASSWORD contains whitespace; IOS would truncate the secret. Exclude whitespace from the password policy." }
    if ($TargetUser -ceq $AdminUser)  { throw "Refusing to rotate the broker's own admin account '$AdminUser'." }

    $AdminPassword = ConvertTo-SecureString $AdminPlain -AsPlainText -Force
    $NewPassword   = ConvertTo-SecureString $PlainNewPassword -AsPlainText -Force
    $VerifyLogin   = -not ($env:CISCO_VERIFY_LOGIN -and $env:CISCO_VERIFY_LOGIN.ToLower() -eq 'false')
    $PrivilegeLevel = if ($env:CISCO_PRIVILEGE_LEVEL) { [int]$env:CISCO_PRIVILEGE_LEVEL } else { 15 }

    # Parse and trim the switch host list
    $SwitchHosts = $SwitchHostsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    if ($SwitchHosts.Count -eq 0) {
        throw "CISCO_SWITCH_HOSTS is set but contains no valid entries after parsing."
    }

    Write-Host "Starting Cisco IOS XE password rotation across $($SwitchHosts.Count) switch(es)."
    Write-Host "  Admin user      : $AdminUser"
    Write-Host "  Target user     : $TargetUser"
    Write-Host "  Privilege level : $PrivilegeLevel"
    Write-Host "  Switches        : $($SwitchHosts -join ', ')"

    # STEP 2: Load Posh-SSH module
    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        throw "Posh-SSH module is not installed. Run: Install-Module Posh-SSH -Scope CurrentUser -Force"
    }
    Import-Module Posh-SSH -ErrorAction Stop
    Write-Host "Posh-SSH module loaded."
    Write-Host ""

    # STEP 3: Rotate password on each switch sequentially
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($SwitchHost in $SwitchHosts) {
        Write-Host "─── Processing switch: $SwitchHost ───────────────────────────────────"
        try {
            Invoke-CiscoPasswordRotation `
                -SwitchHost     $SwitchHost `
                -AdminUser      $AdminUser `
                -AdminPassword  $AdminPassword `
                -TargetUser     $TargetUser `
                -NewPassword    $NewPassword `
                -EnableSecret   $EnableSecret `
                -PrivilegeLevel $PrivilegeLevel

            if ($VerifyLogin -and -not (Test-CiscoLogin -SwitchHost $SwitchHost -User $TargetUser -Password $NewPassword)) {

                throw "Password was applied, but login as '$TargetUser' with it FAILED."

            }

            $results.Add([PSCustomObject]@{ Host = $SwitchHost; Status = 'SUCCESS'; Error = '' })
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Warning "  [$SwitchHost] Rotation FAILED: $errMsg"
            $results.Add([PSCustomObject]@{ Host = $SwitchHost; Status = 'FAILED'; Error = $errMsg })
        }
        Write-Host ""
    }

    # STEP 4: Print summary
    Write-Host "═══════════════════════════════════════════════════════════════"
    Write-Host "Rotation Summary – user '$TargetUser'"
    Write-Host "═══════════════════════════════════════════════════════════════"
    foreach ($r in $results) {
        $icon = if ($r.Status -eq 'SUCCESS') { '[OK]' } else { '[FAIL]' }
        $line = "  $icon  $($r.Host)"
        if ($r.Error) { $line += "  – $($r.Error)" }
        Write-Host $line
    }
    Write-Host "═══════════════════════════════════════════════════════════════"

    $failedCount = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count

    # ── Emit the result as JSON on stdout (the only stdout output) ──────────
    # Emitted even on partial failure so the broker can store the new secret
    # for the switches that did rotate; the exit code still signals failure.
    $resultObj = [ordered]@{
        login    = $TargetUser
        password = $PlainNewPassword
        rotated  = $SwitchHosts.Count - $failedCount
        failed   = $failedCount
        login_verified = $VerifyLogin
        results  = @($results | ForEach-Object { [ordered]@{ hostname = $_.Host; status = $(if ($_.Status -eq 'SUCCESS') { 'OK' } else { 'FAIL' }) } })
    }
    Write-Output ($resultObj | ConvertTo-Json -Compress -Depth 3)

    if ($failedCount -gt 0) {
        Write-Error "Password rotation completed with $failedCount failure(s) out of $($SwitchHosts.Count) switch(es). Review the summary above."
        exit 1
    }

    Write-Host "All $($SwitchHosts.Count) switch(es) rotated successfully."
    exit 0
}
catch {
    Write-Error "Password rotation FAILED: $($_.Exception.Message)"
    exit 1
}
