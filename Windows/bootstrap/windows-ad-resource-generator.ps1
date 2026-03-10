#Requires -Module ActiveDirectory

<#
.SYNOPSIS
    Queries Active Directory for all domain-joined Windows servers and the AD domain itself,
    outputting a combined JSON array compatible with the Britive Access Broker resource format.

.DESCRIPTION
    Produces two categories of resource entries:
      - One "Windows" entry per enabled, domain-joined Windows Server computer (FQDN in parameters)
      - One "ActiveDirectory" entry for the AD domain itself (full DNS domain in parameters)

    Environment labels are inferred from server hostnames and OU paths for server entries,
    and from the domain name for the AD domain entry.

.PARAMETER OUPath
    Optional. Distinguished Name of an OU to restrict the server search.
    Example: "OU=Servers,DC=contoso,DC=com"
    Omit to search the entire domain.

.PARAMETER IncludeOffline
    Optional. By default, servers that do not respond to a ping are excluded.
    Use this switch to include them regardless.

.EXAMPLE
    .\windows-ad-resource-generator.ps1

.EXAMPLE
    .\windows-ad-resource-generator.ps1 -OUPath "OU=Servers,DC=contoso,DC=com"

.EXAMPLE
    .\windows-ad-resource-generator.ps1 -IncludeOffline
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

    if ($ServerName -match "(?i)(prod|prd)")           { return "Production" }
    if ($ServerName -match "(?i)(dev|development)")    { return "Development" }
    if ($ServerName -match "(?i)(test|tst|qa)")        { return "Test" }
    if ($ServerName -match "(?i)(stage|staging|stg)")  { return "Staging" }

    if ($CanonicalName -match "(?i)Production")  { return "Production" }
    if ($CanonicalName -match "(?i)Development") { return "Development" }
    if ($CanonicalName -match "(?i)Test")        { return "Test" }
    if ($CanonicalName -match "(?i)Staging")     { return "Staging" }

    return "Development"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "Active Directory PowerShell module is not installed. Install RSAT tools and retry."
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    # -------------------------------------------------------------------------
    # Section 1: Windows Server entries
    # -------------------------------------------------------------------------
    $searchParams = @{
        Filter     = 'OperatingSystem -like "*Server*" -and Enabled -eq $true'
        Properties = @('DNSHostName', 'CanonicalName')
    }

    if ($OUPath) {
        $searchParams['SearchBase'] = $OUPath
    }

    Write-Verbose "Querying Active Directory for domain-joined Windows Server computers..."
    $adServers = Get-ADComputer @searchParams

    $results = @()

    if ($adServers) {
        Write-Verbose "Found $(@($adServers).Count) server(s). Building resource list..."

        foreach ($server in $adServers) {
            # Prefer DNSHostName (FQDN); fall back to SAM account Name if DNS is unpopulated
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
    }
    else {
        Write-Warning "No Windows Server computers found in Active Directory."
    }

    # -------------------------------------------------------------------------
    # Section 2: ActiveDirectory domain entry
    # -------------------------------------------------------------------------
    Write-Verbose "Retrieving AD domain information..."
    $domain = Get-ADDomain

    # Use the NetBIOS name as the display name and DNSRoot as the full domain FQDN
    $domainEnvironment = Get-ServerEnvironment -ServerName $domain.DNSRoot -CanonicalName $domain.DNSRoot

    $results += [PSCustomObject]@{
        type       = "ActiveDirectory"
        name       = $domain.Name
        labels     = @{
            Environment = @($domainEnvironment)
        }
        parameters = @{
            domain = $domain.DNSRoot
        }
    }

    # -------------------------------------------------------------------------
    # Output
    # -------------------------------------------------------------------------
    Write-Verbose "Total resource entries: $($results.Count)"

    $json = $results | ConvertTo-Json -Depth 5

    # ConvertTo-Json omits the surrounding array brackets for a single object;
    # wrap manually so the output is always a valid JSON array
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
