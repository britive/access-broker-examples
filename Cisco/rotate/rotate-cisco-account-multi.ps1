# ============================================================
# Cisco IOS XE Account Password Rotation – Multiple Switches
# ============================================================
# Rotates the password for a local user account across a
# group of Cisco Catalyst 9300 (IOS XE) switches via SSH.
# Each switch is processed in sequence. Results are reported
# per-switch; the script exits 1 if any switch fails.
#
# Required env vars:
#   CISCO_SWITCH_HOSTS    – Comma-separated list of switch IPs
#                           or hostnames (e.g. "10.0.1.1,10.0.1.2")
#   CISCO_ADMIN_USER      – Admin username (same across all switches)
#   CISCO_ADMIN_PASSWORD  – Admin password (same across all switches)
#   CISCO_TARGET_USER     – Local username whose password to rotate
#   CISCO_NEW_PASSWORD    – The new password to set
#
# Optional env vars:
#   CISCO_ENABLE_SECRET   – Enable mode secret (only needed if the
#                           admin account is not privilege 15)
#   CISCO_PRIVILEGE_LEVEL – Privilege level for the target user
#                           (default: 15)
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

        $sshSession = New-SSHSession `
            -ComputerName $SwitchHost `
            -Credential $Credential `
            -AcceptKey `
            -Force `
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
            if ($output -match '[>#]') { break }
            Start-Sleep -Milliseconds 300
        }
        if (-not ($output -match '[>#]')) {
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
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $stream.WriteLine("username $TargetUser privilege $PrivilegeLevel algorithm-type scrypt secret $plainPassword")
        $setCmdOutput = $stream.Expect('(config)', [TimeSpan]::FromSeconds(10))
        if (-not $setCmdOutput) {
            throw "Timed out waiting for config prompt after setting password."
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

# ─── Main ────────────────────────────────────────────────────────────────────

try {
    # STEP 1: Validate required environment variables
    if (-not $env:CISCO_SWITCH_HOSTS)   { throw "CISCO_SWITCH_HOSTS environment variable is not set. Provide a comma-separated list of switch IPs/hostnames." }
    if (-not $env:CISCO_ADMIN_USER)     { throw "CISCO_ADMIN_USER environment variable is not set. Cannot authenticate to switches." }
    if (-not $env:CISCO_ADMIN_PASSWORD) { throw "CISCO_ADMIN_PASSWORD environment variable is not set. Cannot authenticate to switches." }
    if (-not $env:CISCO_TARGET_USER)    { throw "CISCO_TARGET_USER environment variable is not set. Cannot identify target account." }
    if (-not $env:CISCO_NEW_PASSWORD)   { throw "CISCO_NEW_PASSWORD environment variable is not set. Cannot rotate password." }

    $AdminUser      = $env:CISCO_ADMIN_USER
    $AdminPassword  = ConvertTo-SecureString $env:CISCO_ADMIN_PASSWORD -AsPlainText -Force
    $TargetUser     = $env:CISCO_TARGET_USER
    $NewPassword    = ConvertTo-SecureString $env:CISCO_NEW_PASSWORD   -AsPlainText -Force
    $EnableSecret   = $env:CISCO_ENABLE_SECRET          # optional
    $PrivilegeLevel = if ($env:CISCO_PRIVILEGE_LEVEL) { [int]$env:CISCO_PRIVILEGE_LEVEL } else { 15 }

    # Parse and trim the switch host list
    $SwitchHosts = $env:CISCO_SWITCH_HOSTS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

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
