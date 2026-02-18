# ============================================================
# Cisco IOS XE Account Password Rotation – Single Switch
# ============================================================
# Rotates the password for a local user account on a single
# Cisco Catalyst 9300 (IOS XE) switch via SSH.
# Used by the Britive broker to reset network device
# credentials as part of a checkout/checkin workflow.
#
# Required env vars:
#   CISCO_SWITCH_HOST     – IP address or hostname of the switch
#   CISCO_ADMIN_USER      – Admin username for the SSH session
#   CISCO_ADMIN_PASSWORD  – Admin password for the SSH session
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

# ─── Helper: open SSH shell, rotate password, save config ───────────────────

function Invoke-CiscoPasswordRotation {
    param (
        [string]$SwitchHost,
        [string]$AdminUser,
        [string]$AdminPassword,
        [string]$TargetUser,
        [string]$NewPassword,
        [string]$EnableSecret,
        [int]$PrivilegeLevel
    )

    $sshSession = $null

    try {
        Write-Host "  Connecting to $SwitchHost via SSH..."

        $SecureAdminPass = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential($AdminUser, $SecureAdminPass)

        $sshSession = New-SSHSession `
            -ComputerName $SwitchHost `
            -Credential $Credential `
            -AcceptKey `
            -Force `
            -ErrorAction Stop

        Write-Host "  SSH session established (SessionId: $($sshSession.SessionId))."

        $stream = New-SSHShellStream -SessionId $sshSession.SessionId -ErrorAction Stop

        # ── Wait for the initial exec prompt (> or #) ──────────────────────
        $output = $stream.Expect('[>#]', [TimeSpan]::FromSeconds(15))
        if (-not $output) {
            throw "Timed out waiting for initial shell prompt on $SwitchHost."
        }

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

        # ── Enter global configuration mode ─────────────────────────────────
        Write-Host "  Entering global configuration mode..."
        $stream.WriteLine("configure terminal")
        $configOutput = $stream.Expect('\(config\)#', [TimeSpan]::FromSeconds(10))
        if (-not $configOutput) {
            throw "Failed to enter global configuration mode on $SwitchHost."
        }

        # ── Rotate the password (scrypt / type-9 hash – IOS XE 16.x+) ──────
        Write-Host "  Setting new password for user: $TargetUser"
        $stream.WriteLine("username $TargetUser privilege $PrivilegeLevel algorithm-type scrypt secret $NewPassword")
        $setCmdOutput = $stream.Expect('\(config\)#', [TimeSpan]::FromSeconds(10))
        if (-not $setCmdOutput) {
            throw "Timed out waiting for config prompt after setting password on $SwitchHost."
        }

        # ── Exit configuration mode ──────────────────────────────────────────
        $stream.WriteLine("end")
        $stream.Expect('#', [TimeSpan]::FromSeconds(5)) | Out-Null

        # ── Persist to NVRAM ─────────────────────────────────────────────────
        Write-Host "  Saving configuration to NVRAM..."
        $stream.WriteLine("write memory")
        $saveOutput = $stream.Expect('\[OK\]|Building configuration|Copy in progress', [TimeSpan]::FromSeconds(30))
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

# ─── Main ────────────────────────────────────────────────────────────────────

try {
    # STEP 1: Validate required environment variables
    if (-not $env:CISCO_SWITCH_HOST)    { throw "CISCO_SWITCH_HOST environment variable is not set. Cannot identify target switch." }
    if (-not $env:CISCO_ADMIN_USER)     { throw "CISCO_ADMIN_USER environment variable is not set. Cannot authenticate to switch." }
    if (-not $env:CISCO_ADMIN_PASSWORD) { throw "CISCO_ADMIN_PASSWORD environment variable is not set. Cannot authenticate to switch." }
    if (-not $env:CISCO_TARGET_USER)    { throw "CISCO_TARGET_USER environment variable is not set. Cannot identify target account." }
    if (-not $env:CISCO_NEW_PASSWORD)   { throw "CISCO_NEW_PASSWORD environment variable is not set. Cannot rotate password." }

    $SwitchHost     = $env:CISCO_SWITCH_HOST
    $AdminUser      = $env:CISCO_ADMIN_USER
    $AdminPassword  = $env:CISCO_ADMIN_PASSWORD
    $TargetUser     = $env:CISCO_TARGET_USER
    $NewPassword    = $env:CISCO_NEW_PASSWORD
    $EnableSecret   = $env:CISCO_ENABLE_SECRET          # optional
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

    Write-Host "Password rotation completed successfully for user '$TargetUser' on switch '$SwitchHost'."
    exit 0
}
catch {
    Write-Error "Password rotation FAILED for user '$($env:CISCO_TARGET_USER)' on switch '$($env:CISCO_SWITCH_HOST)': $($_.Exception.Message)"
    exit 1
}
