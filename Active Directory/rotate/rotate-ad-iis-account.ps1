# ============================================================
# Active Directory IIS App Pool Password Rotation
# ============================================================
# Rotates the password for an AD service account, then updates
# the IIS Application Pool identity credential on a remote IIS
# server via PSRemoting (WinRM), and optionally recycles it.
#
# Required env vars:
#   AD_TARGET_USER    – SamAccountName of the service account
#   AD_NEW_PASSWORD   – The new password to set on the account
#   AD_TARGET_SERVER  – Hostname/FQDN of the IIS server
#   AD_APPPOOL_NAME   – Name of the IIS Application Pool to update
#
# Optional env vars:
#   AD_RECYCLE_APPPOOL – "true" (default) or "false"
#
# Prerequisites:
#   - WinRM/PSRemoting must be enabled on the target IIS server
#   - The broker service account must have remote admin access
#   - RSAT Active Directory module must be installed on the broker
#   - WebAdministration module must be installed on the IIS server
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
        throw "AD_TARGET_SERVER environment variable is not set. Cannot connect to remote IIS server."
    }
    if (-not $env:AD_APPPOOL_NAME) {
        throw "AD_APPPOOL_NAME environment variable is not set. Cannot identify target app pool."
    }

    $TargetUser    = $env:AD_TARGET_USER
    $NewPassword   = $env:AD_NEW_PASSWORD
    $TargetServer  = $env:AD_TARGET_SERVER
    $AppPoolName   = $env:AD_APPPOOL_NAME

    # Default to recycling the app pool unless explicitly set to "false"
    $RecycleAppPool = if ($env:AD_RECYCLE_APPPOOL -eq "false") { $false } else { $true }

    # Log parameters (never log the password itself)
    Write-Host "Starting IIS app pool account password rotation..."
    Write-Host "  Target user   : $TargetUser"
    Write-Host "  Target server : $TargetServer"
    Write-Host "  App pool name : $AppPoolName"
    Write-Host "  Recycle pool  : $RecycleAppPool"

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
    # required by IIS app pool identity configuration
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
    # STEP 5: Update the IIS app pool credential on the remote server
    # ==========================================================
    # Use Invoke-Command (PSRemoting/WinRM) to run commands on
    # the target IIS server under the broker's service account identity.
    Write-Host "Connecting to remote IIS server: $TargetServer"

    Invoke-Command -ComputerName $TargetServer -ErrorAction Stop -ScriptBlock {
        param($poolName, $poolAccount, $poolPassword, $shouldRecycle)

        $ErrorActionPreference = 'Stop'

        # ----------------------------------------------------------
        # Import the WebAdministration module (provides IIS:\ PSDrive)
        # Available on IIS 7.5+ (Server 2008 R2 and later)
        # ----------------------------------------------------------
        Import-Module WebAdministration -ErrorAction Stop
        Write-Host "  WebAdministration module loaded."

        # ----------------------------------------------------------
        # Verify the app pool exists on this server
        # ----------------------------------------------------------
        $poolPath = "IIS:\AppPools\$poolName"
        $pool = Get-Item $poolPath -ErrorAction Stop
        Write-Host "  Found app pool: $poolName [State: $($pool.state)]"

        # ----------------------------------------------------------
        # Update the app pool identity to use the service account
        # identityType 3 = SpecificUser (custom AD account)
        # Set explicitly even if already SpecificUser, to be safe
        # ----------------------------------------------------------
        Set-ItemProperty $poolPath -Name processModel.identityType -Value 3
        Set-ItemProperty $poolPath -Name processModel.userName -Value $poolAccount
        Set-ItemProperty $poolPath -Name processModel.password -Value $poolPassword

        Write-Host "  App pool identity updated: $poolAccount"

        # ----------------------------------------------------------
        # Optionally recycle the app pool for the new credential
        # to take effect immediately
        # ----------------------------------------------------------
        if ($shouldRecycle) {
            Write-Host "  Recycling app pool: $poolName"
            Restart-WebAppPool -Name $poolName -ErrorAction Stop

            # Brief pause to let the app pool restart
            Start-Sleep -Seconds 3

            # Verify the app pool is running after recycle
            $pool = Get-Item $poolPath
            if ($pool.state -ne 'Started') {
                throw "App pool '$poolName' is not running after recycle. Current state: $($pool.state)"
            }
            Write-Host "  App pool recycled and running."
        }
        else {
            Write-Host "  App pool recycle skipped (AD_RECYCLE_APPPOOL=false)."
            Write-Host "  The new credential will take effect on next app pool recycle."
        }

    } -ArgumentList $AppPoolName, $serviceAccount, $NewPassword, $RecycleAppPool

    Write-Host "IIS app pool account rotation completed successfully."
    Write-Host "  User     : $TargetUser"
    Write-Host "  Server   : $TargetServer"
    Write-Host "  App pool : $AppPoolName"
    exit 0
}
catch {
    Write-Error "IIS app pool account rotation FAILED: $($_.Exception.Message)"
    exit 1
}
