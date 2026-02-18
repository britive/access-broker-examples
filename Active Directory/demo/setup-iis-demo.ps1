# ============================================================
# Demo: Set Up a Sample IIS Web Application on Windows Server 2022
# ============================================================
# This script sets up a basic IIS web application with a custom
# Application Pool running under an AD service account.
# Use this to test the rotate-ad-iis-account.ps1 rotation script.
#
# Run this script as Administrator on a Windows Server 2022 machine
# that is domain-joined.
#
# What this script does:
#   1. Installs the IIS Web Server role and management tools
#   2. Creates an AD service account for the app pool
#   3. Creates a custom IIS Application Pool using that account
#   4. Creates a sample IIS website with a basic default page
#   5. Outputs the configuration for reference
#
# Prerequisites:
#   - Windows Server 2022 (domain-joined)
#   - Run as Administrator
#   - Active Directory module available (RSAT)
# ============================================================

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# Configuration — adjust these values for your environment
# ----------------------------------------------------------
$ServiceAccountName = "svc-iis-demo"             # AD service account to create
$ServiceAccountPassword = "P@ssw0rd!Demo2024"     # Initial password (will be rotated by broker)
$AppPoolName = "DemoAppPool"                      # IIS Application Pool name
$SiteName = "DemoWebSite"                         # IIS Site name
$SitePort = 8080                                  # Port for the demo site
$SitePath = "C:\inetpub\demosite"                 # Physical path for the site content

Write-Host "============================================"
Write-Host " IIS Demo Setup — Windows Server 2022"
Write-Host "============================================"

try {
    # ==========================================================
    # STEP 1: Install IIS Web Server role and management tools
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 1] Installing IIS Web Server role..."

    # Install IIS with management tools and PowerShell module
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop
    Write-Host "  IIS Web Server role installed."

    # Install the WebAdministration PowerShell module (needed for app pool management)
    Install-WindowsFeature -Name Web-Scripting-Tools -ErrorAction Stop
    Write-Host "  Web scripting tools installed."

    # Import the module to verify it works
    Import-Module WebAdministration -ErrorAction Stop
    Write-Host "  WebAdministration module loaded."

    # ==========================================================
    # STEP 2: Create an AD service account for the app pool
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 2] Creating AD service account: $ServiceAccountName"

    Import-Module ActiveDirectory -ErrorAction Stop

    # Check if the account already exists
    $existingUser = Get-ADUser -Filter {SamAccountName -eq $ServiceAccountName} -ErrorAction SilentlyContinue

    if ($existingUser) {
        Write-Host "  Service account '$ServiceAccountName' already exists. Skipping creation."
    }
    else {
        $securePass = ConvertTo-SecureString $ServiceAccountPassword -AsPlainText -Force

        New-ADUser `
            -Name $ServiceAccountName `
            -SamAccountName $ServiceAccountName `
            -AccountPassword $securePass `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -Description "Demo IIS service account for Britive broker rotation testing" `
            -ErrorAction Stop

        Write-Host "  Service account '$ServiceAccountName' created and enabled."
    }

    # Build DOMAIN\username format for IIS
    $domain = Get-ADDomain
    $domainAccount = "$($domain.NetBIOSName)\$ServiceAccountName"
    Write-Host "  Domain account: $domainAccount"

    # ==========================================================
    # STEP 3: Create the IIS Application Pool
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 3] Creating IIS Application Pool: $AppPoolName"

    # Remove existing app pool if it exists (clean setup)
    if (Test-Path "IIS:\AppPools\$AppPoolName") {
        Remove-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        Write-Host "  Removed existing app pool."
    }

    # Create a new app pool
    New-WebAppPool -Name $AppPoolName -ErrorAction Stop
    Write-Host "  App pool created."

    # Configure the app pool to run under the AD service account
    # identityType 3 = SpecificUser (custom account)
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.identityType -Value 3
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.userName -Value $domainAccount
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.password -Value $ServiceAccountPassword

    Write-Host "  App pool identity set to: $domainAccount"

    # ==========================================================
    # STEP 4: Create a sample IIS website
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 4] Creating demo website: $SiteName"

    # Create the site content directory
    if (-not (Test-Path $SitePath)) {
        New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
        Write-Host "  Created site directory: $SitePath"
    }

    # Create a simple default page
    $htmlContent = @"
<!DOCTYPE html>
<html>
<head><title>Britive IIS Demo</title></head>
<body>
    <h1>Britive IIS Rotation Demo</h1>
    <p>This site is running under app pool: <strong>$AppPoolName</strong></p>
    <p>Service account: <strong>$domainAccount</strong></p>
    <p>If you can see this page, the app pool identity credential is working.</p>
</body>
</html>
"@
    $htmlContent | Out-File "$SitePath\index.html" -Encoding utf8 -Force
    Write-Host "  Created default page: $SitePath\index.html"

    # Remove existing site if it exists (clean setup)
    if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
        Remove-Website -Name $SiteName -ErrorAction SilentlyContinue
        Write-Host "  Removed existing site."
    }

    # Create the website bound to the custom app pool
    New-Website `
        -Name $SiteName `
        -PhysicalPath $SitePath `
        -ApplicationPool $AppPoolName `
        -Port $SitePort `
        -ErrorAction Stop

    Write-Host "  Website created on port $SitePort."

    # ==========================================================
    # STEP 5: Verify and output configuration
    # ==========================================================
    Write-Host ""
    Write-Host "============================================"
    Write-Host " Demo Setup Complete"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "IIS Site:"
    Write-Host "  Name      : $SiteName"
    Write-Host "  URL       : http://localhost:$SitePort"
    Write-Host "  Path      : $SitePath"
    Write-Host ""
    Write-Host "App Pool:"
    Write-Host "  Name      : $AppPoolName"
    Write-Host "  Identity  : $domainAccount"
    Write-Host ""
    Write-Host "Service Account:"
    Write-Host "  Username  : $ServiceAccountName"
    Write-Host "  Domain    : $($domain.NetBIOSName)"
    Write-Host ""
    Write-Host "To test rotation, set these environment variables and run rotate-ad-iis-account.ps1:"
    Write-Host "  `$env:AD_TARGET_USER    = '$ServiceAccountName'"
    Write-Host "  `$env:AD_NEW_PASSWORD   = '<new-password>'"
    Write-Host "  `$env:AD_TARGET_SERVER  = '$($env:COMPUTERNAME)'"
    Write-Host "  `$env:AD_APPPOOL_NAME   = '$AppPoolName'"
    Write-Host ""

    exit 0
}
catch {
    Write-Error "Demo setup FAILED: $($_.Exception.Message)"
    exit 1
}
