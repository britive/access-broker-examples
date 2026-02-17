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
# The demo service is a minimal C# executable compiled inline
# that implements the Windows SCM interface. It does nothing
# useful but provides a real service to test credential rotation.
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
$ServiceExePath = "C:\BritiveDemo\BritiveDemoService.exe" # Path for the compiled service binary

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
    # STEP 3: Compile a minimal C# Windows service executable
    # ==========================================================
    Write-Host ""
    Write-Host "[Step 3] Compiling demo service executable..."

    # Create the directory for the service binary
    $serviceDir = Split-Path -Path $ServiceExePath -Parent
    if (-not (Test-Path $serviceDir)) {
        New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null
    }

    # Minimal C# Windows service that implements the SCM interface.
    # It simply starts, logs a heartbeat to a file, and waits to be stopped.
    # This is the minimum needed for a valid Windows service binary.
    $serviceSource = @'
using System;
using System.IO;
using System.ServiceProcess;
using System.Timers;

public class BritiveDemoService : ServiceBase
{
    private Timer _timer;
    private string _logFile = @"C:\BritiveDemo\service.log";

    public BritiveDemoService()
    {
        ServiceName = "BritiveDemoService";
    }

    protected override void OnStart(string[] args)
    {
        Log("Service started as: " + Environment.UserName);
        _timer = new Timer(60000);
        _timer.Elapsed += (s, e) => Log("Heartbeat - running as: " + Environment.UserName);
        _timer.Start();
    }

    protected override void OnStop()
    {
        if (_timer != null) _timer.Stop();
        Log("Service stopped.");
    }

    private void Log(string message)
    {
        try
        {
            File.AppendAllText(_logFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " - " + message + Environment.NewLine);
        }
        catch { }
    }

    public static void Main()
    {
        ServiceBase.Run(new BritiveDemoService());
    }
}
'@

    # Compile the C# source into a Windows service executable
    # using the .NET Framework compiler built into Windows
    Add-Type -TypeDefinition $serviceSource `
        -ReferencedAssemblies "System.ServiceProcess" `
        -OutputAssembly $ServiceExePath `
        -OutputType ConsoleApplication `
        -ErrorAction Stop

    Write-Host "  Service binary compiled: $ServiceExePath"

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

    # Create the service using sc.exe with the compiled binary
    $createResult = & sc.exe create $ServiceName binPath= $ServiceExePath start= demand DisplayName= $ServiceDisplayName 2>&1
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
    Write-Host "  Binary       : $ServiceExePath"
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
