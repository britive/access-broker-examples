# ============================================================
# Active Directory Service Account Password Rotation
# ============================================================
# Rotates the password for an AD service account, then updates
# the logon credential on a Windows service running on a remote
# server via PSRemoting (WinRM), and optionally restarts it.
#
# Required env vars:
#   AD_TARGET_USER    – SamAccountName of the service account
#   AD_NEW_PASSWORD   – The new password to set on the account
#   AD_TARGET_SERVER  – Hostname/FQDN of the server running the service
#   AD_SERVICE_NAME   – Name of the Windows service to update
#
# Optional env vars:
#   AD_RESTART_SERVICE – "true" (default) or "false"
#
# Prerequisites:
#   - WinRM/PSRemoting must be enabled on the target server
#   - The broker service account must have remote admin access
#   - RSAT Active Directory module must be installed
# ============================================================

$ErrorActionPreference = 'Stop'

try {
    # ==========================================================
    # STEP 1: Validate all required environment variables
    # ==========================================================
    if (-not $env:AD_TARGET_USER) {
        throw "AD_TARGET_USER environment variable is not set. Cannot identify target account."
    }
    if (-not $env:AD_NEW_PASSWORD) {
        throw "AD_NEW_PASSWORD environment variable is not set. Cannot rotate password."
    }
    if (-not $env:AD_TARGET_SERVER) {
        throw "AD_TARGET_SERVER environment variable is not set. Cannot connect to remote server."
    }
    if (-not $env:AD_SERVICE_NAME) {
        throw "AD_SERVICE_NAME environment variable is not set. Cannot identify target service."
    }

    $TargetUser    = $env:AD_TARGET_USER
    $NewPassword   = $env:AD_NEW_PASSWORD
    $TargetServer  = $env:AD_TARGET_SERVER
    $ServiceName   = $env:AD_SERVICE_NAME

    # Default to restarting the service unless explicitly set to "false"
    $RestartService = if ($env:AD_RESTART_SERVICE -eq "false") { $false } else { $true }

    # Log parameters (never log the password itself)
    Write-Host "Starting service account password rotation..."
    Write-Host "  Target user   : $TargetUser"
    Write-Host "  Target server : $TargetServer"
    Write-Host "  Service name  : $ServiceName"
    Write-Host "  Restart service: $RestartService"

    # ==========================================================
    # STEP 2: Import the Active Directory module
    # ==========================================================
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "ActiveDirectory module loaded."

    # ==========================================================
    # STEP 3: Verify the target user exists in AD
    # ==========================================================
    $adUser = Get-ADUser -Identity $TargetUser -ErrorAction Stop
    Write-Host "Confirmed user exists: $($adUser.SamAccountName)"

    # Retrieve the domain NetBIOS name to build DOMAIN\username format
    # needed by sc.exe when updating the service logon account
    $domain = Get-ADDomain -ErrorAction Stop
    $domainPrefix = $domain.NetBIOSName
    $serviceAccount = "$domainPrefix\$TargetUser"
    Write-Host "Service account logon name: $serviceAccount"

    # ==========================================================
    # STEP 4: Rotate the AD password
    # ==========================================================
    $SecurePass = ConvertTo-SecureString $NewPassword -AsPlainText -Force

    Set-ADAccountPassword `
        -Identity $TargetUser `
        -NewPassword $SecurePass `
        -Reset `
        -ErrorAction Stop

    Write-Host "AD password updated successfully."

    # Unlock the account in case it was locked out, and ensure
    # the user is NOT forced to change password at next logon
    Unlock-ADAccount -Identity $TargetUser -ErrorAction SilentlyContinue
    Set-ADUser -Identity $TargetUser -ChangePasswordAtLogon $false -ErrorAction Stop

    Write-Host "Account unlocked and password-change-at-logon disabled."

    # ==========================================================
    # STEP 5: Update the service credential on the remote server
    # ==========================================================
    # Use Invoke-Command (PSRemoting/WinRM) to run commands on
    # the target server under the broker's service account identity.
    Write-Host "Connecting to remote server: $TargetServer"

    Invoke-Command -ComputerName $TargetServer -ErrorAction Stop -ScriptBlock {
        param($svcName, $svcAccount, $svcPassword, $shouldRestart)

        $ErrorActionPreference = 'Stop'

        # ----------------------------------------------------------
        # Verify the service exists on this server
        # ----------------------------------------------------------
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        Write-Host "  Found service: $($svc.DisplayName) [Status: $($svc.Status)]"

        # ----------------------------------------------------------
        # Update the service logon credential using sc.exe
        # sc.exe is universally available across Windows versions
        # ----------------------------------------------------------
        $scResult = & sc.exe config $svcName obj= $svcAccount password= $svcPassword 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "sc.exe config failed (exit code $LASTEXITCODE): $scResult"
        }
        Write-Host "  Service credential updated via sc.exe."

        # ----------------------------------------------------------
        # Optionally restart the service for the new credential
        # to take effect immediately
        # ----------------------------------------------------------
        if ($shouldRestart) {
            Write-Host "  Stopping service: $svcName"
            Stop-Service -Name $svcName -Force -ErrorAction Stop

            # Wait for the service to fully stop (timeout 60 seconds)
            $svc = Get-Service -Name $svcName
            $stopTimeout = 60
            $stopTimer = 0
            while ($svc.Status -ne 'Stopped' -and $stopTimer -lt $stopTimeout) {
                Start-Sleep -Seconds 2
                $stopTimer += 2
                $svc = Get-Service -Name $svcName
            }
            if ($svc.Status -ne 'Stopped') {
                throw "Service '$svcName' did not stop within $stopTimeout seconds."
            }
            Write-Host "  Service stopped."

            Write-Host "  Starting service: $svcName"
            Start-Service -Name $svcName -ErrorAction Stop

            # Wait for the service to fully start (timeout 60 seconds)
            $svc = Get-Service -Name $svcName
            $startTimeout = 60
            $startTimer = 0
            while ($svc.Status -ne 'Running' -and $startTimer -lt $startTimeout) {
                Start-Sleep -Seconds 2
                $startTimer += 2
                $svc = Get-Service -Name $svcName
            }
            if ($svc.Status -ne 'Running') {
                throw "Service '$svcName' did not start within $startTimeout seconds. Current status: $($svc.Status)"
            }
            Write-Host "  Service restarted and running."
        }
        else {
            Write-Host "  Service restart skipped (AD_RESTART_SERVICE=false)."
            Write-Host "  The new credential will take effect on next service restart."
        }

    } -ArgumentList $ServiceName, $serviceAccount, $NewPassword, $RestartService

    Write-Host "Service account rotation completed successfully."
    Write-Host "  User    : $TargetUser"
    Write-Host "  Server  : $TargetServer"
    Write-Host "  Service : $ServiceName"
    exit 0
}
catch {
    Write-Error "Service account rotation FAILED: $($_.Exception.Message)"
    exit 1
}
