#Requires -Modules ActiveDirectory
# ad_setup.ps1
# One-time AD setup for the dual-account rotation demo.
# Creates a demo OU, a shared security group, and two service accounts (A/B)
# that Britive will rotate. Idempotent-ish: skips objects that already exist.
#
# Adjust the variables below to match your directory before running.

[CmdletBinding()]
param(
    [string]$Domain     = "example.local",
    [string]$OU         = "OU=BritiveDemo,DC=example,DC=local",
    [string]$OUName     = "BritiveDemo",
    [string]$OUPath     = "DC=example,DC=local",
    [string]$GroupName  = "svc-webapp-demo",
    [string]$AccountA   = "svc-webapp-a",
    [string]$AccountB   = "svc-webapp-b"
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    # Initial password prompted (never hardcode); Britive owns rotation after setup.
    $InitialPwd = Read-Host "Initial password for the demo service accounts" -AsSecureString

    # Create the demo OU if it doesn't exist
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OU'" -ErrorAction SilentlyContinue)) {
        Write-Host "Creating OU '$OUName'..." -ForegroundColor Cyan
        New-ADOrganizationalUnit -Name $OUName -Path $OUPath -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
    } else {
        Write-Host "OU '$OU' already exists. Skipping." -ForegroundColor Yellow
    }

    # Create the shared group if it doesn't exist
    if (-not (Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue)) {
        Write-Host "Creating group '$GroupName'..." -ForegroundColor Cyan
        New-ADGroup -Name $GroupName -GroupScope Global -GroupCategory Security -Path $OU `
            -Description "Dual-account rotation demo (A/B web app identity)" -ErrorAction Stop
    } else {
        Write-Host "Group '$GroupName' already exists. Skipping." -ForegroundColor Yellow
    }

    # Create both service accounts if missing, then add to the shared group
    foreach ($acct in @($AccountA, $AccountB)) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$acct'" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating account '$acct'..." -ForegroundColor Cyan
            New-ADUser `
                -Name                 $acct `
                -SamAccountName        $acct `
                -UserPrincipalName     "$acct@$Domain" `
                -Path                  $OU `
                -AccountPassword       $InitialPwd `
                -PasswordNeverExpires  $true `
                -CannotChangePassword  $false `
                -Enabled               $true `
                -Description           "Dual-account rotation demo identity" `
                -ErrorAction Stop
        } else {
            Write-Host "Account '$acct' already exists. Skipping create." -ForegroundColor Yellow
        }

        Add-ADGroupMember -Identity $GroupName -Members $acct -ErrorAction Stop
    }

    Write-Host "Created/verified $AccountA and $AccountB in '$GroupName'. Britive will own rotation from here." -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "AD setup failed: $($_.Exception.Message)"
    exit 1
}
