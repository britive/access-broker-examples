# ============================================================
# Windows VM IAM-Style Broker Scan (remote)
# ============================================================
# Runs on the Britive broker. Connects to a target Windows VM
# over WinRM (Invoke-Command), enumerates LOCAL users and groups
# (and group membership), builds a JSON payload in the Britive
# Resource Manager schema, and writes it to the broker-supplied
# output path.
#
# Required env var:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  – full path for JSON output
#
# Connection env vars (mirror the local-admin-remote-server scripts):
#   target (or BRITIVE_REMOTE_HOST)   – target VM hostname/IP   (required)
#   BRITIVE_REMOTE_USER               – WinRM user (optional; omit to use broker identity)
#   BRITIVE_REMOTE_PASSWORD           – WinRM password (optional, paired with user)
#
# Identity IDs use the local account Name so that
# attribute_resolution.group_membership = "id" resolves correctly.
# Members reference local user Names; SID is stored in attributes.
# ============================================================

try {
    $ErrorActionPreference = 'Stop'

    if (-not $env:BROKER_INJECTED_SCAN_OUTPUT_PATH) {
        throw "BROKER_INJECTED_SCAN_OUTPUT_PATH environment variable is not set. Cannot write scan output."
    }
    $outputPath = $env:BROKER_INJECTED_SCAN_OUTPUT_PATH

    $targetComputer = if ($env:target) { $env:target } elseif ($env:BRITIVE_REMOTE_HOST) { $env:BRITIVE_REMOTE_HOST } else { $null }
    if (-not $targetComputer) {
        throw "Target computer not set. Provide env var 'target' or 'BRITIVE_REMOTE_HOST'."
    }

    Write-Host "Running Windows VM IAM-style broker scan against $targetComputer..."
    Write-Host "Output path: $outputPath"

    # ensure output directory exists
    $outputDir = Split-Path -Path $outputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-Host "Created output directory: $outputDir"
    }

    # optional explicit credential for WinRM
    $invokeParams = @{ ComputerName = $targetComputer }
    if ($env:BRITIVE_REMOTE_USER -and $env:BRITIVE_REMOTE_PASSWORD) {
        $secPass = ConvertTo-SecureString $env:BRITIVE_REMOTE_PASSWORD -AsPlainText -Force
        $invokeParams.Credential = New-Object System.Management.Automation.PSCredential($env:BRITIVE_REMOTE_USER, $secPass)
    }

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
