# ============================================================
# Cisco IOS XE Account Password Rotation – Single Switch
# ============================================================
# Rotates the password for a local user account on a single
# Cisco Catalyst 9300 (IOS XE) switch via SSH.
# Used by the Britive broker to reset network device
# credentials as part of a checkout/checkin workflow.
#
# Device connection values are read from CISCO_* first and fall
# back to the resource attributes the broker injects for a
# rotation (RESOURCE_<NAME>, upper-cased):
#   CISCO_SWITCH_HOST    / RESOURCE_SWITCH_HOST    – switch IP or hostname
#   CISCO_ADMIN_USER     / RESOURCE_ADMIN_USER     – admin username for SSH
#   CISCO_ADMIN_PASSWORD / RESOURCE_ADMIN_PASSWORD – admin password for SSH
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

# ─── Helper: open SSH shell, rotate password, save config ───────────────────

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
        Write-Host "  Connecting to $SwitchHost via SSH..."

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

        Write-Host "  SSH session established (SessionId: $($sshSession.SessionId))."

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
            throw "Timed out waiting for initial shell prompt on $SwitchHost."
        }

        # Drain any data that arrived after the first prompt character
        # (remainder of MOTD, terminal negotiation bytes) so the buffer is
        # clean before we start sending commands and calling Expect.
        Start-Sleep -Milliseconds 500
        $stream.Read() | Out-Null

        # ── If in user EXEC mode (>), elevate to privileged EXEC (#) ───────
        if ($output -match '>\s*$') {
            Write-Host "  Entering privileged EXEC mode via 'enable'..."
            $stream.WriteLine("enable")

            $passPrompt = $stream.Expect('Password:', [TimeSpan]::FromSeconds(5))
            if (-not $passPrompt) {
                throw "Timed out waiting for enable password prompt on $SwitchHost."
            }

            $stream.WriteLine($EnableSecret)

            $privOutput = $stream.Expect('#', [TimeSpan]::FromSeconds(5))
            if (-not $privOutput) {
                throw "Failed to enter privileged EXEC mode on $SwitchHost. Verify CISCO_ENABLE_SECRET."
            }
            Write-Host "  Privileged EXEC mode entered."
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
        Write-Host "  Entering global configuration mode..."
        $stream.WriteLine("configure terminal")
        $configOutput = $stream.Expect('(config)', [TimeSpan]::FromSeconds(10))
        if (-not $configOutput) {
            throw "Failed to enter global configuration mode on $SwitchHost."
        }

        # ── Rotate the password (scrypt / type-9 hash – IOS XE 16.x+) ──────
        # Decrypt SecureString only at the point of use inside the encrypted SSH session.
        Write-Host "  Setting new password for user: $TargetUser"
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
            throw "Timed out waiting for config prompt after setting password on $SwitchHost."
        }
        if ($setCmdOutput -match '% (Invalid|Incomplete|Ambiguous|Password)') {
            throw "$SwitchHost rejected the new password for '$TargetUser'."
        }

        # ── Exit configuration mode ──────────────────────────────────────────
        $stream.WriteLine("end")
        $endOutput = $stream.Expect('#', [TimeSpan]::FromSeconds(5))
        if (-not $endOutput) {
            throw "Timed out waiting for privileged EXEC prompt after 'end' on $SwitchHost."
        }

        # ── Persist to NVRAM ─────────────────────────────────────────────────
        Write-Host "  Saving configuration to NVRAM..."
        $stream.WriteLine("write memory")
        $saveOutput = $stream.Expect('Building configuration', [TimeSpan]::FromSeconds(30))
        if (-not $saveOutput) {
            throw "Timed out waiting for 'write memory' to complete on $SwitchHost."
        }

        # Allow write memory to fully finish before closing the session
        Start-Sleep -Milliseconds 500
        $stream.Read() | Out-Null

        Write-Host "  Configuration saved."
        Write-Host "  Password rotation completed successfully on $SwitchHost."
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
    $SwitchHost       = if ($env:CISCO_SWITCH_HOST)    { $env:CISCO_SWITCH_HOST }    else { $env:RESOURCE_SWITCH_HOST }
    $AdminUser        = if ($env:CISCO_ADMIN_USER)     { $env:CISCO_ADMIN_USER }     else { $env:RESOURCE_ADMIN_USER }
    $AdminPlain       = if ($env:CISCO_ADMIN_PASSWORD) { $env:CISCO_ADMIN_PASSWORD } else { $env:RESOURCE_ADMIN_PASSWORD }
    $EnableSecret     = if ($env:CISCO_ENABLE_SECRET)  { $env:CISCO_ENABLE_SECRET }  else { $env:RESOURCE_ENABLE_SECRET }   # optional
    $TargetUser       = $env:CISCO_TARGET_USER
    $PlainNewPassword = $env:CISCO_NEW_PASSWORD

    if (-not $SwitchHost)       { throw "CISCO_SWITCH_HOST (or resource attribute SWITCH_HOST) is not set. Cannot identify target switch." }
    if (-not $AdminUser)        { throw "CISCO_ADMIN_USER (or resource attribute ADMIN_USER) is not set. Cannot authenticate to switch." }
    if (-not $AdminPlain)       { throw "CISCO_ADMIN_PASSWORD (or resource attribute ADMIN_PASSWORD) is not set. Cannot authenticate to switch." }
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

    Write-Host "Starting Cisco IOS XE password rotation."
    Write-Host "  Target switch   : $SwitchHost"
    Write-Host "  Admin user      : $AdminUser"
    Write-Host "  Target user     : $TargetUser"
    Write-Host "  Privilege level : $PrivilegeLevel"

    # STEP 2: Load Posh-SSH module
    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        throw "Posh-SSH module is not installed. Run: Install-Module Posh-SSH -Scope CurrentUser -Force"
    }
    Import-Module Posh-SSH -ErrorAction Stop
    Write-Host "Posh-SSH module loaded."

    # STEP 3: Connect to switch and rotate password
    Invoke-CiscoPasswordRotation `
        -SwitchHost     $SwitchHost `
        -AdminUser      $AdminUser `
        -AdminPassword  $AdminPassword `
        -TargetUser     $TargetUser `
        -NewPassword    $NewPassword `
        -EnableSecret   $EnableSecret `
        -PrivilegeLevel $PrivilegeLevel

    $LoginVerified = $false
    if ($VerifyLogin) {
        Write-Host "  Verifying login as '$TargetUser' with the new password..."
        if (-not (Test-CiscoLogin -SwitchHost $SwitchHost -User $TargetUser -Password $NewPassword)) {
            throw "Password was applied, but login as '$TargetUser' with it FAILED. Treat the account as unusable until re-rotated."
        }
        $LoginVerified = $true
        Write-Host "  Login verified."
    }

    Write-Host "Password rotation completed successfully for user '$TargetUser' on switch '$SwitchHost'."

    # ── Emit the result as JSON on stdout (the only stdout output) ──────────
    # The broker captures this to update the stored secret for the account.
    Write-Output ([ordered]@{ login = $TargetUser; hostname = $SwitchHost; password = $PlainNewPassword; login_verified = $LoginVerified } | ConvertTo-Json -Compress)
    exit 0
}
catch {
    Write-Error "Password rotation FAILED for user '$($env:CISCO_TARGET_USER)' on switch '$SwitchHost': $($_.Exception.Message)"
    exit 1
}
