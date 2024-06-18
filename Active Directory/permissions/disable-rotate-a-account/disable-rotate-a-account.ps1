# Powershell script example to rotate credentials and disable user's "-a" account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkin
$Email = $env:user

# Strip the username from the email address and append "-a"
# Allowing the sue-case to fulfilled by user email as the aprameter sent by Britive
$Username = ($Email -split "@")[0] + "-a"

# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

if (-not $User) {
    Write-Host "User $Username does not exist and hence can not be DISABLED."

} else {
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

    # Disable the -a user account and DO NOT share the rotated password at checkin
    Disable-ADAccount -Identity $User
    Write-Host "User $Username has been DISABLED."
}