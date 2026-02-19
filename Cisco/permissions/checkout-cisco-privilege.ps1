# ============================================================
# Cisco IOS XE – Privilege Escalation Checkout (Single Switch)
# ============================================================
# Creates a local user account with elevated privilege on a
# Cisco Catalyst 9300 (IOS XE) switch via SSH.
# Used by the Britive Access Broker for Just-In-Time (JIT)
# privileged access: the account is created on checkout and
# removed on checkin.
#
# Required env vars:
#   CISCO_SWITCH_HOST         – IP address or hostname of the switch
#   CISCO_ADMIN_USER          – Admin username for the SSH session
#   CISCO_ADMIN_PASSWORD      – Admin password for the SSH session
#   CISCO_TARGET_USER         – Local username to create / escalate
#   CISCO_TARGET_PASSWORD     – Password to set on the target account
#
# Optional env vars:
#   CISCO_ENABLE_SECRET       – Enable mode secret (only needed if
#                               the admin account is not privilege 15)
#   CISCO_ESCALATED_PRIVILEGE – Privilege level to grant (default: 15)
# ============================================================

$ErrorActionPreference = 'Stop'

# ─── Helper: open SSH shell, create/escalate user, save config ───────────────

function Invoke-CiscoPrivilegeCheckout {
    param (
        [string]$SwitchHost,
        [string]$AdminUser,
        [SecureString]$AdminPassword,
        [string]$TargetUser,
        [SecureString]$TargetPassword,
        [string]$EnableSecret,
        [int]$EscalatedPrivilege
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

        # Allow the switch time to send its MOTD banner and initial prompt
        # before Expect starts reading; without this pause the buffer may be
        # empty and the 15-second wait times out before any data arrives.
        Start-Sleep -Milliseconds 1000

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

        # ── Create / escalate the user account (scrypt / type-9 – IOS XE 16.x+) ──
        # Decrypt SecureString only at the point of use inside the encrypted SSH session.
        Write-Host "  Creating / escalating user '$TargetUser' to privilege $EscalatedPrivilege..."
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TargetPassword)
        $plainTargetPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $stream.WriteLine("username $TargetUser privilege $EscalatedPrivilege algorithm-type scrypt secret $plainTargetPassword")
        $setCmdOutput = $stream.Expect('\(config\)#', [TimeSpan]::FromSeconds(10))
        if (-not $setCmdOutput) {
            throw "Timed out waiting for config prompt after creating user on $SwitchHost."
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
        $saveOutput = $stream.Expect('\[OK\]|Building configuration|Copy in progress', [TimeSpan]::FromSeconds(30))
        if (-not $saveOutput) {
            throw "Timed out waiting for 'write memory' to complete on $SwitchHost."
        }

        # Allow write memory to fully finish before closing the session
        Start-Sleep -Milliseconds 500
        $stream.Read() | Out-Null

        Write-Host "  Configuration saved."
        Write-Host "  User '$TargetUser' created/escalated to privilege $EscalatedPrivilege on $SwitchHost."
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
    if (-not $env:CISCO_SWITCH_HOST)     { throw "CISCO_SWITCH_HOST environment variable is not set. Cannot identify target switch." }
    if (-not $env:CISCO_ADMIN_USER)      { throw "CISCO_ADMIN_USER environment variable is not set. Cannot authenticate to switch." }
    if (-not $env:CISCO_ADMIN_PASSWORD)  { throw "CISCO_ADMIN_PASSWORD environment variable is not set. Cannot authenticate to switch." }
    if (-not $env:CISCO_TARGET_USER)     { throw "CISCO_TARGET_USER environment variable is not set. Cannot identify target account." }
    if (-not $env:CISCO_TARGET_PASSWORD) { throw "CISCO_TARGET_PASSWORD environment variable is not set. Cannot set account password." }

    $SwitchHost         = $env:CISCO_SWITCH_HOST
    $AdminUser          = $env:CISCO_ADMIN_USER
    $AdminPassword      = ConvertTo-SecureString $env:CISCO_ADMIN_PASSWORD  -AsPlainText -Force
    $TargetUser         = $env:CISCO_TARGET_USER
    $TargetPassword     = ConvertTo-SecureString $env:CISCO_TARGET_PASSWORD -AsPlainText -Force
    $EnableSecret       = $env:CISCO_ENABLE_SECRET           # optional
    $EscalatedPrivilege = if ($env:CISCO_ESCALATED_PRIVILEGE) { [int]$env:CISCO_ESCALATED_PRIVILEGE } else { 15 }

    Write-Host "Starting Cisco IOS XE privilege checkout (account creation)."
    Write-Host "  Target switch      : $SwitchHost"
    Write-Host "  Admin user         : $AdminUser"
    Write-Host "  Target user        : $TargetUser"
    Write-Host "  Escalated privilege: $EscalatedPrivilege"

    # STEP 2: Load Posh-SSH module
    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        throw "Posh-SSH module is not installed. Run: Install-Module Posh-SSH -Scope CurrentUser -Force"
    }
    Import-Module Posh-SSH -ErrorAction Stop
    Write-Host "Posh-SSH module loaded."

    # STEP 3: Connect and escalate
    Invoke-CiscoPrivilegeCheckout `
        -SwitchHost         $SwitchHost `
        -AdminUser          $AdminUser `
        -AdminPassword      $AdminPassword `
        -TargetUser         $TargetUser `
        -TargetPassword     $TargetPassword `
        -EnableSecret       $EnableSecret `
        -EscalatedPrivilege $EscalatedPrivilege

    Write-Host "Checkout completed: user '$TargetUser' has privilege $EscalatedPrivilege on switch '$SwitchHost'."
    exit 0
}
catch {
    Write-Error "Checkout FAILED for user '$($env:CISCO_TARGET_USER)' on switch '$($env:CISCO_SWITCH_HOST)': $($_.Exception.Message)"
    exit 1
}
