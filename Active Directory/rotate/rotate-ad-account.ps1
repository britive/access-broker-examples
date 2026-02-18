# ============================================================
# Active Directory Account Password Rotation
# ============================================================
# Rotates the password for a specified AD account.
# Used by the Britive broker to reset service or user account
# credentials as part of a checkout/checkin workflow.
#
# Required env vars:
#   AD_TARGET_USER  – SamAccountName of the account to rotate
#   AD_NEW_PASSWORD – The new password to set on the account
# ============================================================

$ErrorActionPreference = 'Stop'

try {
    # ----------------------------------------------------------
    # Validate required environment variables
    # ----------------------------------------------------------
    if (-not $env:AD_TARGET_USER) {
        throw "AD_TARGET_USER environment variable is not set. Cannot identify target account."
    }

    if (-not $env:AD_NEW_PASSWORD) {
        throw "AD_NEW_PASSWORD environment variable is not set. Cannot rotate password."
    }

    $TargetUser  = $env:AD_TARGET_USER
    $NewPassword = $env:AD_NEW_PASSWORD

    # Log target user (never log the password itself)
    Write-Host "Starting password rotation for user: $TargetUser"

    # ----------------------------------------------------------
    # Import the Active Directory module
    # ----------------------------------------------------------
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "ActiveDirectory module loaded."

    # ----------------------------------------------------------
    # Verify the target user exists in AD before attempting reset
    # ----------------------------------------------------------
    $adUser = Get-ADUser -Identity $TargetUser -ErrorAction Stop
    Write-Host "Confirmed user exists: $($adUser.SamAccountName)"

    # ----------------------------------------------------------
    # Convert the new password to a SecureString and reset
    # ----------------------------------------------------------
    $SecurePass = ConvertTo-SecureString $NewPassword -AsPlainText -Force

    Set-ADAccountPassword `
        -Identity $TargetUser `
        -NewPassword $SecurePass `
        -Reset `
        -ErrorAction Stop

    Write-Host "Password updated successfully."

    # ----------------------------------------------------------
    # Unlock the account in case it was locked out, and ensure
    # the user is NOT forced to change password at next logon
    # ----------------------------------------------------------
    Unlock-ADAccount -Identity $TargetUser -ErrorAction SilentlyContinue
    Set-ADUser -Identity $TargetUser -ChangePasswordAtLogon $false -ErrorAction Stop

    Write-Host "Account unlocked and password-change-at-logon disabled."
    Write-Host "Password rotation completed successfully for user: $TargetUser"
    exit 0
}
catch {
    Write-Error "Password rotation FAILED for user '$($env:AD_TARGET_USER)': $($_.Exception.Message)"
    exit 1
}
