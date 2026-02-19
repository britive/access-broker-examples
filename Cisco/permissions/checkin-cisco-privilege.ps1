# ============================================================
# Cisco IOS XE – Privilege Escalation Checkin (Single Switch)
# ============================================================
# Removes a local user account from a Cisco Catalyst 9300
# (IOS XE) switch via SSH.
# Used by the Britive Access Broker for Just-In-Time (JIT)
# privileged access: the account is created on checkout and
# removed on checkin.
#
# Required env vars:
#   CISCO_SWITCH_HOST    – IP address or hostname of the switch
#   CISCO_ADMIN_USER     – Admin username for the SSH session
#   CISCO_ADMIN_PASSWORD – Admin password for the SSH session
#   CISCO_TARGET_USER    – Local username to remove
#
# Optional env vars:
#   CISCO_ENABLE_SECRET  – Enable mode secret (only needed if
#                          the admin account is not privilege 15)
# ============================================================

$ErrorActionPreference = 'Stop'

# ─── Helper: open SSH shell, remove user, save config ────────────────────────

function Invoke-CiscoPrivilegeCheckin {
    param (
        [string]$SwitchHost,
        [string]$AdminUser,
        [SecureString]$AdminPassword,
        [string]$TargetUser,
        [string]$EnableSecret
    )

    $sshSession = $null

    try {
        Write-Host "  Connecting to $SwitchHost via SSH..."

        $Credential = New-Object System.Management.Automation.PSCredential($AdminUser, $AdminPassword)

        $sshSession = New-SSHSession `
            -ComputerName $SwitchHost `
            -Credential $Credential `
            -AcceptKey `
            -Force `
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
            if ($output -match '[>#]') { break }
            Start-Sleep -Milliseconds 300
        }
        if (-not ($output -match '[>#]')) {
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

        # ── Enter global configuration mode ─────────────────────────────────
        Write-Host "  Entering global configuration mode..."
        $stream.WriteLine("configure terminal")
        $configOutput = $stream.Expect('(config)', [TimeSpan]::FromSeconds(10))
        if (-not $configOutput) {
            throw "Failed to enter global configuration mode on $SwitchHost."
        }

        # ── Remove the user account ──────────────────────────────────────────
        Write-Host "  Removing user '$TargetUser'..."
        $stream.WriteLine("no username $TargetUser")
        $removeCmdOutput = $stream.Expect('(config)', [TimeSpan]::FromSeconds(10))
        if (-not $removeCmdOutput) {
            throw "Timed out waiting for config prompt after removing user on $SwitchHost."
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
        Write-Host "  User '$TargetUser' removed from $SwitchHost."
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

    $SwitchHost    = $env:CISCO_SWITCH_HOST
    $AdminUser     = $env:CISCO_ADMIN_USER
    $AdminPassword = ConvertTo-SecureString $env:CISCO_ADMIN_PASSWORD -AsPlainText -Force
    $TargetUser    = $env:CISCO_TARGET_USER
    $EnableSecret  = $env:CISCO_ENABLE_SECRET    # optional

    Write-Host "Starting Cisco IOS XE privilege checkin (account removal)."
    Write-Host "  Target switch : $SwitchHost"
    Write-Host "  Admin user    : $AdminUser"
    Write-Host "  Target user   : $TargetUser"

    # STEP 2: Load Posh-SSH module
    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        throw "Posh-SSH module is not installed. Run: Install-Module Posh-SSH -Scope CurrentUser -Force"
    }
    Import-Module Posh-SSH -ErrorAction Stop
    Write-Host "Posh-SSH module loaded."

    # STEP 3: Connect and remove user
    Invoke-CiscoPrivilegeCheckin `
        -SwitchHost    $SwitchHost `
        -AdminUser     $AdminUser `
        -AdminPassword $AdminPassword `
        -TargetUser    $TargetUser `
        -EnableSecret  $EnableSecret

    Write-Host "Checkin completed: user '$TargetUser' removed from switch '$SwitchHost'."
    exit 0
}
catch {
    Write-Error "Checkin FAILED for user '$($env:CISCO_TARGET_USER)' on switch '$($env:CISCO_SWITCH_HOST)': $($_.Exception.Message)"
    exit 1
}
