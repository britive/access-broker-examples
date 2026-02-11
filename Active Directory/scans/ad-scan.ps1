# ============================================================
# Active Directory IAM-Style Broker Scan
# ============================================================
# Scans AD for all users and groups, builds a JSON payload in
# the Britive Resource Manager schema, and writes it to the
# path supplied by the broker via environment variable.
#
# Required env var:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  – full path for the JSON output file
#
# Identity IDs use DistinguishedName for uniqueness.
# Group member lists reference user DistinguishedNames so that
# attribute_resolution.group_membership = "id" resolves correctly.
# ============================================================

try {
    # ----------------------------------------------------------
    # Fail-fast: treat every error as terminating inside this block
    # ----------------------------------------------------------
    $ErrorActionPreference = 'Stop'

    # ----------------------------------------------------------
    # Validate the broker-injected output path is present
    # ----------------------------------------------------------
    if (-not $env:BROKER_INJECTED_SCAN_OUTPUT_PATH) {
        throw "BROKER_INJECTED_SCAN_OUTPUT_PATH environment variable is not set. Cannot write scan output."
    }

    $outputPath = $env:BROKER_INJECTED_SCAN_OUTPUT_PATH
    Write-Host "Running AD IAM-style broker scan..."
    Write-Host "Output path: $outputPath"

    # ----------------------------------------------------------
    # Ensure the output directory exists (broker may not create it)
    # ----------------------------------------------------------
    $outputDir = Split-Path -Path $outputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-Host "Created output directory: $outputDir"
    }

    # ----------------------------------------------------------
    # Import the Active Directory module
    # ----------------------------------------------------------
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "ActiveDirectory module loaded successfully."

    # ----------------------------------------------------------
    # Retrieve domain information for metadata
    # ----------------------------------------------------------
    $domain = Get-ADDomain
    $domainDN = $domain.DistinguishedName
    Write-Host "Connected to domain: $($domain.DNSRoot) ($domainDN)"

    # Timestamp used across all records
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $identities = @()
    $groups     = @()

    # ==========================================================
    # USERS – scan all AD user accounts
    # ==========================================================
    Write-Host "Scanning users..."

    # Retrieve users with the properties needed for the output schema.
    # DistinguishedName is returned by default; the rest are explicit.
    $adUsers = Get-ADUser -Filter * -Properties Mail, GivenName, Surname, UserPrincipalName, Enabled

    foreach ($user in $adUsers) {
        # Use DistinguishedName as the unique identity ID
        $userDN = $user.DistinguishedName

        # Fall back to placeholder values when optional attributes are empty
        $email     = if ($user.Mail)      { $user.Mail }      else { "$($user.SamAccountName)@placeholder.local" }
        $firstName = if ($user.GivenName) { $user.GivenName } else { "NA" }
        $lastName  = if ($user.Surname)   { $user.Surname }   else { "NA" }

        $identities += @{
            id          = $userDN
            name        = $user.SamAccountName
            type        = "User"
            description = "Active Directory user"
            created_on  = $now
            is_active   = [bool]$user.Enabled
            attributes  = @{
                email                = $email
                first_name           = $firstName
                last_name            = $lastName
                samaccountname       = $user.SamAccountName
                user_principal_name  = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { "" }
                distinguished_name   = $userDN
            }
        }
    }

    Write-Host "Found $($identities.Count) users."

    # ==========================================================
    # GROUPS – scan all AD groups and their direct members
    # ==========================================================
    Write-Host "Scanning groups..."

    $adGroups = Get-ADGroup -Filter * -Properties DistinguishedName

    foreach ($group in $adGroups) {
        $groupDN = $group.DistinguishedName
        $members = @()

        # Get direct group members (not recursive) to avoid issues with
        # circular nesting and token-size limits in large environments.
        # Only include user objects; nested groups are excluded.
        try {
            Get-ADGroupMember -Identity $group.ObjectGUID -ErrorAction SilentlyContinue |
                Where-Object { $_.objectClass -eq "user" } |
                ForEach-Object { $members += $_.DistinguishedName }
        }
        catch {
            # Some built-in/protected groups may deny read access
            Write-Host "Warning: Could not enumerate members for group: $($group.Name)"
        }

        $groups += @{
            id          = $groupDN
            name        = $group.Name
            type        = "User group"
            description = "Active Directory group"
            created_on  = $now
            is_active   = $true
            members     = $members
            attributes  = @{
                samaccountname     = $group.SamAccountName
                distinguished_name = $groupDN
            }
        }
    }

    Write-Host "Found $($groups.Count) groups."

    # ==========================================================
    # BUILD OUTPUT – assemble the Britive Resource Manager schema
    # ==========================================================
    $output = @{
        data = @{
            identities         = $identities
            groups             = $groups
            permissions        = @()   # AD has no separate permission objects
            permission_mapping = @()   # User-to-group mapping lives in groups.members
        }
        metadata = @{
            resource_id   = $domainDN
            resource_type = "ActiveDirectory"
            scan_time     = $now
            scan_details  = "AD scan completed. Users: $($identities.Count), Groups: $($groups.Count)"
            scan_errors   = ""
            attribute_resolution = @{
                group_membership   = "id"   # groups.members values match identity.id (DistinguishedName)
                permission_mapping = "id"
            }
        }
    }

    # ----------------------------------------------------------
    # Write JSON output to the broker-specified path
    # ----------------------------------------------------------
    $output | ConvertTo-Json -Depth 10 | Out-File $outputPath -Encoding utf8 -Force
    Write-Host "AD Broker scan completed successfully."
    exit 0
}
catch {
    # ==========================================================
    # ERROR HANDLER – write a minimal valid JSON so the broker
    # can report the failure reason back to the platform.
    # ==========================================================
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

    # Only attempt to write the error file if we have a valid output path
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
