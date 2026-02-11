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
# Identity IDs use SamAccountName (short, fits native_id column limits).
# Group member lists reference user SamAccountNames so that
# attribute_resolution.group_membership = "id" resolves correctly.
# DistinguishedName and UPN are stored in attributes for reference.
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
        # Use SamAccountName as the identity ID (fits native_id column limits)
        $uid = $user.SamAccountName

        # Fall back to placeholder values when optional attributes are empty
        $email     = if ($user.Mail)      { $user.Mail }      else { "$uid@placeholder.local" }
        $firstName = if ($user.GivenName) { $user.GivenName } else { "NA" }
        $lastName  = if ($user.Surname)   { $user.Surname }   else { "NA" }

        $identities += @{
            id          = $uid
            name        = $uid
            type        = "User"
            description = "Active Directory user"
            created_on  = $now
            is_active   = [bool]$user.Enabled
            attributes  = @{
                email                = $email
                first_name           = $firstName
                last_name            = $lastName
                samaccountname       = $uid
                user_principal_name  = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { "" }
                distinguished_name   = $user.DistinguishedName
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
        $groupName = $group.Name
        $members = @()

        # Get direct group members (not recursive) to avoid issues with
        # circular nesting and token-size limits in large environments.
        # Only include user objects; nested groups are excluded.
        # Members stored as SamAccountName to match identity id values.
        try {
            Get-ADGroupMember -Identity $group.ObjectGUID -ErrorAction SilentlyContinue |
                Where-Object { $_.objectClass -eq "user" } |
                ForEach-Object { $members += $_.SamAccountName }
        }
        catch {
            # Some built-in/protected groups may deny read access
            Write-Host "Warning: Could not enumerate members for group: $groupName"
        }

        $groups += @{
            id          = $groupName
            name        = $groupName
            type        = "User group"
            description = "Active Directory group"
            created_on  = $now
            is_active   = $true
            members     = $members
            attributes  = @{
                samaccountname     = $group.SamAccountName
                distinguished_name = $group.DistinguishedName
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
                group_membership   = "id"   # groups.members values match identity.id (SamAccountName)
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
