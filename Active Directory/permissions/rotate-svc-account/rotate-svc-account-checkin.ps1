# Powershell script example to rotate credentials for a service account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkin
$Username = $env:svcaccount

# Get the SamAccountName from username of the service account
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

# Check if user exists
if (-not $User) {
    # The user account does not exist and hence no action required upon check-in
    Write-Output "User $Username does not exist and hence password can not be rotated."
}
else {
    # Generate a new password based on the following policy constraints
    # Define the length of the password
    $length = 12
    # Define characters to be used in the password
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_-+=[]{}|;:,.<>?/~"
    # Generate the password
    $password = ""
    for ($i = 0; $i -lt $length; $i++) {
        $password += $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
    }
    $SecurePassword = ConvertTo-SecureString $password -AsPlainText -Force
    
    # Set the password for the on check-in and DO NOT share new password
    Set-ADAccountPassword -Identity $Username -NewPassword $SecurePassword -Reset
    Write-Output "Account $Username password reset."
}