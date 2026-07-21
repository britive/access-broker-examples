# ============================================================
# Windows VM IAM-Style Broker Scan (remote, provision-cred variant)
# ============================================================
# Reads broker-injected resource params from RESOURCE_* env vars.
# NOTE: the broker injects these as PLAINTEXT into the process
# environment. The base64 form seen in broker logs is only a
# logging/masking representation — do NOT decode here.
#
# Broker-injected params (plaintext):
#   RESOURCE_HOST                 – target VM hostname/IP            (required)
#   RESOURCE_PROVISION_USERNAME   – WinRM admin user                (default: Administrator)
#   RESOURCE_PROVISION_PASSWORD   – WinRM admin password            (required)
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH – full path for JSON output    (required)
#
# The provisioning credential is always used (Basic auth) — local admin
# accounts fail over Negotiate/Kerberos from the broker service context.
# Basic over HTTP requires WinRM 'AllowUnencrypted=true' on the target
# (or use HTTPS/5986).
# ============================================================

try {
    $ErrorActionPreference = 'Stop'

    if (-not $env:BROKER_INJECTED_SCAN_OUTPUT_PATH) {
        throw "BROKER_INJECTED_SCAN_OUTPUT_PATH environment variable is not set. Cannot write scan output."
    }
    $outputPath = $env:BROKER_INJECTED_SCAN_OUTPUT_PATH

    # ---- resolve broker-injected resource params (RESOURCE_*, plaintext) ----
    $targetComputer = $env:RESOURCE_HOST
    if (-not $targetComputer) {
        throw "Target host not set. Provide resource param 'HOST' (env RESOURCE_HOST)."
    }

    $remoteUser = if ($env:RESOURCE_PROVISION_USERNAME) { $env:RESOURCE_PROVISION_USERNAME } else { "Administrator" }

    $remotePass = $env:RESOURCE_PROVISION_PASSWORD
    if (-not $remotePass) {
        throw "Provisioning password not set. Provide resource param 'PROVISION_PASSWORD' (env RESOURCE_PROVISION_PASSWORD)."
    }

    Write-Host "Running Windows VM IAM-style broker scan against $targetComputer..."
    Write-Host "Output path: $outputPath"

    # ensure output directory exists
    $outputDir = Split-Path -Path $outputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-Host "Created output directory: $outputDir"
    }

    # ---- WinRM invocation params ----
    $invokeParams = @{ ComputerName = $targetComputer }

    # Fast-fail timeouts: OpenTimeout bounds the WinRM connect so an unreachable
    # or slow target aborts in ~15s instead of hanging on the default timeouts.
    $invokeParams.SessionOption = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 120000 -CancelTimeout 5000

    $secPass = ConvertTo-SecureString $remotePass -AsPlainText -Force
    $invokeParams.Credential = New-Object System.Management.Automation.PSCredential($remoteUser, $secPass)
    # Basic auth: local accounts fail over Negotiate/Kerberos from a service
    # (broker) context with error 0x8009030d. Basic forces a clean local logon.
    $invokeParams.Authentication = 'Basic'
    Write-Host "Using provisioning credential (Basic auth) for user: $remoteUser"

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # ----------------------------------------------------------
    # Remote scan block — runs ON the target VM. Returns a single
    # object with raw user/group records; the broker assembles the
    # final schema so all JSON formatting happens in one place.
    # ----------------------------------------------------------
    $scriptBlock = {
        $users = @()
        foreach ($u in Get-LocalUser) {
            $users += [PSCustomObject]@{
                name       = $u.Name
                enabled    = [bool]$u.Enabled
                sid        = $u.SID.Value
                fullname   = if ($u.FullName) { $u.FullName } else { "" }
                desc       = if ($u.Description) { $u.Description } else { "" }
            }
        }

        $groups = @()
        foreach ($g in Get-LocalGroup) {
            $members = @()
            try {
                Get-LocalGroupMember -Group $g.Name -ErrorAction Stop | ForEach-Object {
                    # ObjectClass is "User" or "Group"; keep user members only,
                    # store the short account name (strip COMPUTER\ or DOMAIN\ prefix)
                    if ($_.ObjectClass -eq 'User') {
                        $members += ($_.Name -split '\\')[-1]
                    }
                }
            } catch {
                # some built-in groups may deny enumeration
            }
            $groups += [PSCustomObject]@{
                name    = $g.Name
                sid     = $g.SID.Value
                desc    = if ($g.Description) { $g.Description } else { "" }
                members = $members
            }
        }

        [PSCustomObject]@{
            computer = $env:COMPUTERNAME
            users    = $users
            groups   = $groups
        }
    }

    $result = Invoke-Command @invokeParams -ScriptBlock $scriptBlock

    # Guard: a null/empty result means the remote block produced nothing (e.g.
    # LocalAccounts cmdlets unavailable on an old OS). Fail so it is reported.
    if (-not $result) {
        throw "Remote scan against $targetComputer returned no data (target may lack Get-LocalUser/Get-LocalGroup)."
    }

    # ----------------------------------------------------------
    # Build identities
    # ----------------------------------------------------------
    $identities = @()
    foreach ($u in $result.users) {
        $fn = "NA"; $ln = "NA"
        if ($u.fullname) {
            $parts = $u.fullname.Trim() -split '\s+', 2
            $fn = $parts[0]
            if ($parts.Count -gt 1) { $ln = $parts[1] }
        }
        $identities += @{
            id          = $u.name
            name        = $u.name
            type        = "User"
            description = "Local Windows user"
            created_on  = $now
            is_active   = [bool]$u.enabled
            attributes  = @{
                username    = $u.name
                email       = "$($u.name)@$($result.computer).local"
                sid         = $u.sid
                first_name  = $fn
                last_name   = $ln
                full_name   = $u.fullname
                user_desc   = $u.desc
            }
        }
    }
    Write-Host "Found $($identities.Count) local users."

    # ----------------------------------------------------------
    # Build groups
    # ----------------------------------------------------------
    $groups = @()
    foreach ($g in $result.groups) {
        $members = @($g.members)
        $groups += @{
            id          = $g.name
            name        = $g.name
            type        = "User group"
            description = "Local Windows group"
            created_on  = $now
            is_active   = $true
            members     = $members
            attributes  = @{
                groupname  = $g.name
                sid        = $g.sid
                group_desc = $g.desc
            }
        }
    }
    Write-Host "Found $($groups.Count) local groups."

    # ----------------------------------------------------------
    # Assemble Britive Resource Manager schema
    # ----------------------------------------------------------
    $output = @{
        data = @{
            identities         = $identities
            groups             = $groups
            permissions        = @()
            permission_mapping = @()
        }
        metadata = @{
            resource_id   = $result.computer
            resource_type = "WindowsVM"
            scan_time     = $now
            scan_details  = "Windows VM scan completed on $($result.computer). Users: $($identities.Count), Groups: $($groups.Count)"
            scan_errors   = ""
            attribute_resolution = @{
                group_membership   = "id"
                permission_mapping = "id"
            }
        }
    }

    $output | ConvertTo-Json -Depth 10 | Out-File $outputPath -Encoding utf8 -Force
    Write-Host "Windows VM broker scan completed successfully."
    exit 0
}
catch {
    Write-Host "Scan failed: $($_.Exception.Message)"

    $errorOutput = @{
        data = @{
            groups             = @()
            identities         = @()
            permissions        = @()
            permission_mapping = @()
        }
        metadata = @{
            scan_errors = $_.Exception.Message
            scan_time   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }

    if ($env:BROKER_INJECTED_SCAN_OUTPUT_PATH) {
        $errorPath = $env:BROKER_INJECTED_SCAN_OUTPUT_PATH
        $errorDir = Split-Path -Path $errorPath -Parent
        if ($errorDir -and -not (Test-Path $errorDir)) {
            New-Item -ItemType Directory -Path $errorDir -Force | Out-Null
        }
        $errorOutput | ConvertTo-Json -Depth 10 | Out-File $errorPath -Encoding utf8 -Force
    }

    exit 1
}
