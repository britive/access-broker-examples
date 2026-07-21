# ============================================================
# Active Directory IAM-Style Broker Scan – Optimised v3
# ============================================================
# Required env var:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH
#
# Changes from v2:
#   - Fixed bug where newline sanitization was overwritten
#   - CNF conflict objects are now skipped
#   - All sanitization applied correctly before truncation
# ============================================================

try {
    $ErrorActionPreference = 'Stop'

    if (-not $env:BROKER_INJECTED_SCAN_OUTPUT_PATH) {
        throw "BROKER_INJECTED_SCAN_OUTPUT_PATH environment variable is not set."
    }

    $outputPath = $env:BROKER_INJECTED_SCAN_OUTPUT_PATH
    Write-Host "Running AD IAM-style broker scan (optimised v3)..."
    Write-Host "Output path: $outputPath"

    $outputDir = Split-Path -Path $outputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "ActiveDirectory module loaded successfully."

    $domain   = Get-ADDomain
    $domainDN = $domain.DistinguishedName
    Write-Host "Connected to domain: $($domain.DNSRoot) ($domainDN)"

    $now        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $identities = [System.Collections.Generic.List[object]]::new()
    $groups     = [System.Collections.Generic.List[object]]::new()

    # USERS
    Write-Host "Scanning users..."
    $adUsers = Get-ADUser -Filter * -Properties Mail, GivenName, Surname, UserPrincipalName, Enabled
    $dnToSam = @{}

    foreach ($user in $adUsers) {
        $uid = $user.SamAccountName
        $dnToSam[$user.DistinguishedName] = $uid

        $identities.Add(@{
            id          = $uid
            name        = $uid
            type        = "User"
            description = "Active Directory user"
            created_on  = $now
            is_active   = [bool]$user.Enabled
            attributes  = @{
                email               = if ($user.Mail)              { $user.Mail }              else { "$uid@placeholder.local" }
                first_name          = if ($user.GivenName)         { $user.GivenName }         else { "NA" }
                last_name           = if ($user.Surname)           { $user.Surname }           else { "NA" }
                samaccountname      = $uid
                user_principal_name = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { "" }
                distinguished_name  = $user.DistinguishedName
            }
        })
    }
    Write-Host "Found $($identities.Count) users."

    # GROUPS
    Write-Host "Scanning groups..."
    $adGroups = Get-ADGroup -Filter * -Properties DistinguishedName, Members
    $skipped  = 0
    $cnfSkipped = 0

    foreach ($group in $adGroups) {
        # Skip CNF conflict objects
        if ($group.Name -match "CNF:") {
            $cnfSkipped++
            continue
        }

        # Sanitize: strip newlines/tabs then truncate to 255
        $groupName = ($group.Name -replace "[\r\n\t]", " ").Trim()
        $groupName = if ($groupName.Length -gt 255) { $groupName.Substring(0, 255) } else { $groupName }

        $members = [System.Collections.Generic.List[string]]::new()

        if ($group.Members.Count -gt 0) {
            foreach ($memberDN in $group.Members) {
                if ($dnToSam.ContainsKey($memberDN)) {
                    $members.Add($dnToSam[$memberDN])
                }
            }
        } else {
            $skipped++
        }

        $groups.Add(@{
            id          = $groupName
            name        = $groupName
            type        = "User group"
            description = "Active Directory group"
            created_on  = $now
            is_active   = $true
            members     = $members.ToArray()
            attributes  = @{
                samaccountname     = $group.SamAccountName
                distinguished_name = $group.DistinguishedName
            }
        })
    }
    Write-Host "Found $($groups.Count) groups ($skipped empty, $cnfSkipped CNF skipped)."

    $output = @{
        data = @{
            identities         = $identities.ToArray()
            groups             = $groups.ToArray()
            permissions        = @()
            permission_mapping = @()
        }
        metadata = @{
            resource_id   = $domainDN
            resource_type = "ActiveDirectory"
            scan_time     = $now
            scan_details  = "AD scan completed. Users: $($identities.Count), Groups: $($groups.Count), Empty groups skipped: $skipped, CNF groups skipped: $cnfSkipped"
            scan_errors   = ""
            attribute_resolution = @{
                group_membership   = "id"
                permission_mapping = "id"
            }
        }
    }

    $output | ConvertTo-Json -Depth 10 | Out-File $outputPath -Encoding utf8 -Force
    Write-Host "AD Broker scan completed successfully."
    exit 0
}
catch {
    Write-Host "Scan failed: $($_.Exception.Message)"

    $errorOutput = @{
        data     = @{ groups = @(); identities = @(); permissions = @(); permission_mapping = @() }
        metadata = @{ scan_errors = $_.Exception.Message; scan_time = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
    }

    if ($env:BROKER_INJECTED_SCAN_OUTPUT_PATH) {
        $errorPath = $env:BROKER_INJECTED_SCAN_OUTPUT_PATH
        $errorDir  = Split-Path -Path $errorPath -Parent
        if ($errorDir -and -not (Test-Path $errorDir)) { New-Item -ItemType Directory -Path $errorDir -Force | Out-Null }
        $errorOutput | ConvertTo-Json -Depth 10 | Out-File $errorPath -Encoding utf8 -Force
    }
    exit 1
}