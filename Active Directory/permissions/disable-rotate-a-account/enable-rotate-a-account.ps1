# Powershell script example to rotate credentials and enable user's "-a" account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkout
$Email = $env:user

# Strip the username from the email address and append "-a"
$Username = ($Email -split "@")[0] + "-a"

# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

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

if (-not $User) {
    # Create user if it doesn't exist
    # Create the new user account and enable it
    New-ADUser -Name $Username `
    -SamAccountName $Username `
    -UserPrincipalName $Email `
    -AccountPassword $SecurePassword `
    -Enabled $true

    # Share New user account information with the end-user
    Write-Output "User account $Username created and enabled."
    Write-Output "username: $Username"
    Write-Output "password: $password"
}
else {
    # Set the password for the user
    Set-ADAccountPassword -Identity $Username -NewPassword $SecurePassword -Reset
    # Enable the account
    Enable-ADAccount -Identity $Username

    # Share new credential information with the end-user
    Write-Output "Account $Username has been enabled and the password has been set."
    Write-Output "username: $Username"
    Write-Output "password: $password"
}