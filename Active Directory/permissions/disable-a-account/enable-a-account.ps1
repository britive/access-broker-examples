# Powershell script example to enable user's "-a" account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkout
$Email = $env:user

# Strip the username from the email address and append "-a"
$Username = ($Email -split "@")[0] + "-a"

# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

if (-not $User) {
    # Create user if it doesn't exist, allowing for smoother access for new uers
    
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
    # Create the new user account and enable it
    New-ADUser -Name $Username `
    -SamAccountName $Username `
    -UserPrincipalName $Email `
    -AccountPassword $SecurePassword `
    -Enabled $true

    Write-Output "User $Username created and enabled."
    Write-Output "username:s:$Username"
    Write-Output "password:s:$SecurePassword"
}
else {
    # Check if the account is disabled
    if ($User.Enabled -eq $false) {
        # Enable the existing user account
        Enable-ADAccount -Identity $User
        Write-Host "User $Username exists and has been enabled."
    } else {
        Write-Host "User $Username already exists and is enabled."
    }
}