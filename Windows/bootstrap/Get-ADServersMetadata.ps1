#Requires -Module ActiveDirectory

<#
.SYNOPSIS
    Scans for all AD domain-joined servers and returns their metadata in JSON format.

.DESCRIPTION
    This script queries Active Directory for all server computer objects and retrieves
    detailed metadata including hostname, OS information, DNS name, IP addresses,
    and custom labels. The output is formatted as a JSON array compatible with
    the Linux resources.sh script format.

.PARAMETER OUPath
    Optional. Specific OU Distinguished Name to search within. If not specified,
    searches the entire domain.

.PARAMETER IncludeOffline
    Optional. Include servers that are currently offline or unreachable.

.EXAMPLE
    .\Get-ADServersMetadata.ps1

.EXAMPLE
    .\Get-ADServersMetadata.ps1 -OUPath "OU=Servers,DC=contoso,DC=com"

.EXAMPLE
    .\Get-ADServersMetadata.ps1 -IncludeOffline
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OUPath,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeOffline
)

# Function to get IP addresses for a server
function Get-ServerIPAddresses {
    param(
        [string]$ComputerName
    )

    try {
        $ipAddresses = @()
        $hostEntry = [System.Net.Dns]::GetHostEntry($ComputerName)
        foreach ($ip in $hostEntry.AddressList) {
            if ($ip.AddressFamily -eq 'InterNetwork') {  # IPv4 only
                $ipAddresses += $ip.IPAddressToString
            }
        }
        return $ipAddresses
    }
    catch {
        Write-Verbose "Unable to resolve IP for $ComputerName : $_"
        return @()
    }
}

# Function to determine server role/tier based on naming convention or OU
function Get-ServerTier {
    param(
        [string]$ServerName,
        [string]$OU
    )

    # Check naming patterns
    if ($ServerName -match "(?i)(web|iis|http)") { return "Web" }
    if ($ServerName -match "(?i)(app|application)") { return "Application" }
    if ($ServerName -match "(?i)(db|database|sql)") { return "Database" }
    if ($ServerName -match "(?i)(dc|domain)") { return "DomainController" }
    if ($ServerName -match "(?i)(file|fs)") { return "FileServer" }

    # Check OU path
    if ($OU -match "(?i)Web Servers") { return "Web" }
    if ($OU -match "(?i)Application Servers") { return "Application" }
    if ($OU -match "(?i)Database Servers") { return "Database" }
    if ($OU -match "(?i)Domain Controllers") { return "DomainController" }

    return "Application"  # Default
}

# Function to determine environment based on naming or OU
function Get-ServerEnvironment {
    param(
        [string]$ServerName,
        [string]$OU
    )

    if ($ServerName -match "(?i)(prod|prd)") { return "Production" }
    if ($ServerName -match "(?i)(dev|development)") { return "Development" }
    if ($ServerName -match "(?i)(test|tst|qa)") { return "Test" }
    if ($ServerName -match "(?i)(stage|staging|stg)") { return "Staging" }

    # Check OU path
    if ($OU -match "(?i)Production") { return "Production" }
    if ($OU -match "(?i)Development") { return "Development" }
    if ($OU -match "(?i)Test") { return "Test" }
    if ($OU -match "(?i)Staging") { return "Staging" }

    return "Development"  # Default
}

# Main script
try {
    # Check if Active Directory module is available
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "Active Directory PowerShell module is not installed. Please install RSAT tools."
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    # Build the AD query
    $searchParams = @{
        Filter = 'OperatingSystem -like "*Server*" -and Enabled -eq $true'
        Properties = @(
            'Name',
            'DNSHostName',
            'OperatingSystem',
            'OperatingSystemVersion',
            'OperatingSystemServicePack',
            'IPv4Address',
            'LastLogonDate',
            'Created',
            'Description',
            'CanonicalName',
            'DistinguishedName',
            'MemberOf'
        )
    }

    if ($OUPath) {
        $searchParams['SearchBase'] = $OUPath
    }

    Write-Verbose "Querying Active Directory for server computers..."
    $adServers = Get-ADComputer @searchParams

    if (-not $adServers) {
        Write-Warning "No servers found in Active Directory."
        Write-Output "[]"
        exit 0
    }

    Write-Verbose "Found $($adServers.Count) server(s). Collecting metadata..."

    # Build metadata array
    $serversMetadata = @()

    foreach ($server in $adServers) {
        Write-Verbose "Processing: $($server.Name)"

        # Test connectivity if not including offline servers
        $isOnline = $true
        if (-not $IncludeOffline) {
            $isOnline = Test-Connection -ComputerName $server.DNSHostName -Count 1 -Quiet -ErrorAction SilentlyContinue
            if (-not $isOnline) {
                Write-Verbose "  Skipping offline server: $($server.Name)"
                continue
            }
        }

        # Get IP addresses
        $ipAddresses = @()
        if ($server.IPv4Address) {
            $ipAddresses += $server.IPv4Address
        }
        else {
            $ipAddresses = Get-ServerIPAddresses -ComputerName $server.DNSHostName
        }

        # Determine OS type string
        $osType = "Windows Server"
        if ($server.OperatingSystem) {
            $osType = $server.OperatingSystem
            if ($server.OperatingSystemVersion) {
                $osType += " ($($server.OperatingSystemVersion))"
            }
        }

        # Determine tier and environment
        $tier = Get-ServerTier -ServerName $server.Name -OU $server.CanonicalName
        $environment = Get-ServerEnvironment -ServerName $server.Name -OU $server.CanonicalName

        # Build metadata object
        $metadata = [PSCustomObject]@{
            name = $server.Name
            type = $osType
            dnsHostName = $server.DNSHostName
            ipAddresses = $ipAddresses
            distinguishedName = $server.DistinguishedName
            description = $server.Description
            created = $server.Created
            lastLogonDate = $server.LastLogonDate
            labels = @{
                Tier = @($tier)
                Environment = @($environment)
            }
        }

        $serversMetadata += $metadata
    }

    if ($serversMetadata.Count -eq 0) {
        Write-Warning "No online/reachable servers found."
        Write-Output "[]"
        exit 0
    }

    Write-Verbose "Successfully collected metadata for $($serversMetadata.Count) server(s)."

    # Convert to JSON and output
    $jsonOutput = $serversMetadata | ConvertTo-Json -Depth 10

    # Ensure array format even for single item
    if ($serversMetadata.Count -eq 1) {
        $jsonOutput = "[$jsonOutput]"
    }

    Write-Output $jsonOutput
}
catch {
    Write-Error "An error occurred: $_"
    Write-Output "[]"
    exit 1
}
