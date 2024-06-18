# Powershell script example to rotate credentials for a service account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkin
$Username = $env:svcaccount

# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

if (-not $User) {
    # Create user if it doesn't exist
    Write-Output "Account $Username does not exist, please make sure the acocunt is created beforehand."
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
    
    # Set the password for the user
    Set-ADAccountPassword -Identity $Username -NewPassword $SecurePassword -Reset
    # Enable the account
    Enable-ADAccount -Identity $Username
    
    # Share credentials with the end user who checked out the profile.
    Write-Output "Account $Username has been enabled and the password has been set."
    Write-Output "username: $Username"
    Write-Output "password: $password"
}