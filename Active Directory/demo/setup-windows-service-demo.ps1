# ============================================================
# Demo: Set Up a Sample Windows Service on Windows Server 2022
# ============================================================
# This script creates a simple Windows service running under an
# AD service account. Use this to test the
# rotate-ad-service-account.ps1 rotation script.
#
# Run this script as Administrator on a Windows Server 2022 machine
# that is domain-joined.
#
# What this script does:
#   1. Creates an AD service account
#   2. Grants the account "Log on as a service" right
#   3. Creates a minimal Windows service using sc.exe
#   4. Configures the service to run under the AD account
#   5. Starts the service and outputs configuration for reference
#
# The demo service uses PowerShell as its executable with a
# simple sleep loop — it does nothing useful but provides a
# real Windows service to test credential rotation against.
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
$ServiceAccountName = "svc-demo-app"              # AD service account to create
$ServiceAccountPassword = "P@ssw0rd!Demo2024"     # Initial password (will be rotated by broker)
$ServiceName = "BritiveDemoService"               # Windows service name
$ServiceDisplayName = "Britive Demo Service"      # Friendly display name
$ServiceDescription = "Demo service for testing Britive broker password rotation"
$ServiceScriptPath = "C:\BritiveDemo\service.ps1" # Path for the service script

Write-Host "============================================"
Write-Host " Windows Service Demo Setup"
Write-Host "============================================"

try {
    # ==========================================================
    # STEP 1: Create an AD service account
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 1] Creating AD service account: $ServiceAccountName"

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
            -Description "Demo Windows service account for Britive broker rotation testing" `
            -ErrorAction Stop

        Write-Host "  Service account '$ServiceAccountName' created and enabled."
    }

    # Build DOMAIN\username format for the service
    $domain = Get-ADDomain
    $domainAccount = "$($domain.NetBIOSName)\$ServiceAccountName"
    Write-Host "  Domain account: $domainAccount"

    # ==========================================================
    # STEP 2: Grant "Log on as a service" right
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 2] Granting 'Log on as a service' right..."

    # Use secedit to export, modify, and import the security policy
    # This grants the service account the SeServiceLogonRight privilege
    $tempDir = "$env:TEMP\BritiveDemo"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    $exportPath = "$tempDir\secpol.cfg"
    $importPath = "$tempDir\secpol_modified.cfg"

    # Export current security policy
    & secedit /export /cfg $exportPath /quiet 2>&1 | Out-Null

    # Read the policy, find the SeServiceLogonRight line, and append the account
    $policyContent = Get-Content $exportPath -Raw

    # Get the SID of the service account for the policy entry
    $userSid = (Get-ADUser -Identity $ServiceAccountName).SID.Value

    if ($policyContent -match "SeServiceLogonRight\s*=\s*(.*)") {
        $currentValue = $matches[1]
        # Check if the SID is already present
        if ($currentValue -notmatch $userSid) {
            $newValue = "$currentValue,*$userSid"
            $policyContent = $policyContent -replace "SeServiceLogonRight\s*=\s*.*", "SeServiceLogonRight = $newValue"
        }
        else {
            Write-Host "  Account already has 'Log on as a service' right."
        }
    }
    else {
        # Add the line if it doesn't exist
        $policyContent = $policyContent -replace "(\[Privilege Rights\])", "`$1`r`nSeServiceLogonRight = *$userSid"
    }

    $policyContent | Out-File $importPath -Encoding unicode -Force

    # Import the modified policy
    & secedit /configure /db "$tempDir\secedit.sdb" /cfg $importPath /quiet 2>&1 | Out-Null

    Write-Host "  'Log on as a service' right granted to $domainAccount."

    # ==========================================================
    # STEP 3: Create the service script
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 3] Creating service script..."

    # Create the directory for the service script
    $serviceDir = Split-Path -Path $ServiceScriptPath -Parent
    if (-not (Test-Path $serviceDir)) {
        New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null
    }

    # Write a minimal PowerShell script that runs as a service.
    # This script just loops indefinitely — it's a placeholder
    # to give us a real service to rotate credentials on.
    $serviceScript = @'
# Britive Demo Service Script
# This script runs as a Windows service and does nothing useful.
# It exists solely to test password rotation via the broker.

$logFile = "C:\BritiveDemo\service.log"

while ($true) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$timestamp - Demo service is running as: $($env:USERNAME)" | Out-File $logFile -Append
    Start-Sleep -Seconds 60
}
'@
    $serviceScript | Out-File $ServiceScriptPath -Encoding utf8 -Force
    Write-Host "  Service script created: $ServiceScriptPath"

    # ==========================================================
    # STEP 4: Create and configure the Windows service
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 4] Creating Windows service: $ServiceName"

    # Remove existing service if it exists (clean setup)
    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        # Stop the service if running
        if ($existingService.Status -eq 'Running') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        # Delete the existing service
        & sc.exe delete $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        Write-Host "  Removed existing service."
    }

    # The service binary is PowerShell executing our script.
    # We use NSSM (Non-Sucking Service Manager) pattern with sc.exe.
    # For a real demo, we use PowerShell's ability to run as a service
    # via a wrapper that sc.exe can manage.
    $binPath = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$ServiceScriptPath`""

    # Create the service using sc.exe
    $createResult = & sc.exe create $ServiceName binPath= $binPath start= demand DisplayName= $ServiceDisplayName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create service (exit code $LASTEXITCODE): $createResult"
    }
    Write-Host "  Service created."

    # Set the service description
    & sc.exe description $ServiceName $ServiceDescription 2>&1 | Out-Null

    # Configure the service to run under the AD service account
    $configResult = & sc.exe config $ServiceName obj= $domainAccount password= $ServiceAccountPassword 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure service account (exit code $LASTEXITCODE): $configResult"
    }
    Write-Host "  Service configured to run as: $domainAccount"

    # ==========================================================
    # STEP 5: Start the service and verify
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 5] Starting the service..."

    Start-Service -Name $ServiceName -ErrorAction Stop
    Start-Sleep -Seconds 3

    $svc = Get-Service -Name $ServiceName
    Write-Host "  Service status: $($svc.Status)"

    # ==========================================================
    # Output configuration summary
    # ==========================================================
    Write-Host ""
    Write-Host "============================================"
    Write-Host " Demo Setup Complete"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "Windows Service:"
    Write-Host "  Name         : $ServiceName"
    Write-Host "  Display Name : $ServiceDisplayName"
    Write-Host "  Status       : $($svc.Status)"
    Write-Host "  Identity     : $domainAccount"
    Write-Host "  Log file     : C:\BritiveDemo\service.log"
    Write-Host ""
    Write-Host "Service Account:"
    Write-Host "  Username     : $ServiceAccountName"
    Write-Host "  Domain       : $($domain.NetBIOSName)"
    Write-Host ""
    Write-Host "To test rotation, set these environment variables and run rotate-ad-service-account.ps1:"
    Write-Host "  `$env:AD_TARGET_USER    = '$ServiceAccountName'"
    Write-Host "  `$env:AD_NEW_PASSWORD   = '<new-password>'"
    Write-Host "  `$env:AD_TARGET_SERVER  = '$($env:COMPUTERNAME)'"
    Write-Host "  `$env:AD_SERVICE_NAME   = '$ServiceName'"
    Write-Host ""

    exit 0
}
catch {
    Write-Error "Demo setup FAILED: $($_.Exception.Message)"
    exit 1
}
