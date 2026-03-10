#Requires -Module ActiveDirectory

<#
.SYNOPSIS
    Queries Active Directory for all domain-joined Windows servers and outputs their
    metadata as a JSON array compatible with the Britive Access Broker resource format.

.DESCRIPTION
    Searches AD for enabled computer objects running a Windows Server OS and emits a
    JSON array where each element contains the server FQDN, type, and resource labels
    (OS and Environment). Environment is inferred from the server hostname or OU path.

.PARAMETER OUPath
    Optional. Distinguished Name of an OU to restrict the search.
    Example: "OU=Servers,DC=contoso,DC=com"
    Omit to search the entire domain.

.PARAMETER IncludeOffline
    Optional. By default, servers that do not respond to a ping are excluded.
    Use this switch to include them regardless.

.EXAMPLE
    .\windows-resource-generator.ps1

.EXAMPLE
    .\windows-resource-generator.ps1 -OUPath "OU=Servers,DC=contoso,DC=com"

.EXAMPLE
    .\windows-resource-generator.ps1 -IncludeOffline
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OUPath,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeOffline
)

# ---------------------------------------------------------------------------
# Helper: infer the Environment label from the server hostname and OU path.
# Hostname naming convention is checked first; OU canonical path is the fallback.
# ---------------------------------------------------------------------------
function Get-ServerEnvironment {
    param(
        [string]$ServerName,
        [string]$CanonicalName
    )

    # Match common environment keywords in the hostname
    if ($ServerName -match "(?i)(prod|prd)")           { return "Production" }
    if ($ServerName -match "(?i)(dev|development)")    { return "Development" }
    if ($ServerName -match "(?i)(test|tst|qa)")        { return "Test" }
    if ($ServerName -match "(?i)(stage|staging|stg)")  { return "Staging" }

    # Fall back to the OU path embedded in the AD canonical name
    if ($CanonicalName -match "(?i)Production")  { return "Production" }
    if ($CanonicalName -match "(?i)Development") { return "Development" }
    if ($CanonicalName -match "(?i)Test")        { return "Test" }
    if ($CanonicalName -match "(?i)Staging")     { return "Staging" }

    return "Development"  # Default when no pattern matches
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    # Verify the ActiveDirectory module is available before importing
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "Active Directory PowerShell module is not installed. Install RSAT tools and retry."
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    # Filter to enabled computers whose OS contains "Server" to exclude workstations
    $searchParams = @{
        Filter     = 'OperatingSystem -like "*Server*" -and Enabled -eq $true'
        Properties = @('DNSHostName', 'CanonicalName')
    }

    # Scope to a specific OU when provided; otherwise search the entire domain
    if ($OUPath) {
        $searchParams['SearchBase'] = $OUPath
    }

    Write-Verbose "Querying Active Directory for domain-joined Windows Server computers..."
    $adServers = Get-ADComputer @searchParams

    if (-not $adServers) {
        Write-Warning "No servers found in Active Directory."
        Write-Output "[]"
        exit 0
    }

    Write-Verbose "Found $(@($adServers).Count) server(s). Building resource list..."

    $results = @()

    foreach ($server in $adServers) {
        # Prefer DNSHostName (FQDN); fall back to the SAM account Name if DNS is unpopulated
        $fqdn = if ($server.DNSHostName) { $server.DNSHostName } else { $server.Name }

        Write-Verbose "Processing: $fqdn"

        # Skip servers that are unreachable unless -IncludeOffline was specified
        if (-not $IncludeOffline) {
            $reachable = Test-Connection -ComputerName $fqdn -Count 1 -Quiet -ErrorAction SilentlyContinue
            if (-not $reachable) {
                Write-Verbose "  Skipping unreachable server: $fqdn"
                continue
            }
        }

        $environment = Get-ServerEnvironment -ServerName $server.Name -CanonicalName $server.CanonicalName

        # Build the resource object matching the Britive Access Broker resource schema
        $results += [PSCustomObject]@{
            type       = "Windows"
            name       = $server.Name
            labels     = @{
                OS          = @("Windows")
                Environment = @($environment)
            }
            parameters = @{
                hostname = $fqdn
            }
        }
    }

    if ($results.Count -eq 0) {
        Write-Warning "No reachable servers found. Use -IncludeOffline to include offline servers."
        Write-Output "[]"
        exit 0
    }

    Write-Verbose "Built resource entries for $($results.Count) server(s)."

    # Serialize to JSON; Depth 5 is sufficient for this structure
    $json = $results | ConvertTo-Json -Depth 5

    # ConvertTo-Json strips the outer array brackets for a single object — wrap manually
    if ($results.Count -eq 1) {
        $json = "[$json]"
    }

    Write-Output $json
}
catch {
    Write-Error "Fatal error: $_"
    Write-Output "[]"
    exit 1
}
