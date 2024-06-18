# Powershell script example to disable user's "-a" account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkin
$Email = $env:user
$GroupName = $env:group

# Strip the username from the email address and append "-a"
$Username = ($Email -split "@")[0] + "-a"

# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

if (-not $User) {
    Write-Host "User $Username does not exist and hence can not be DISABLED."

} else {
    # Check if the account is disabled
    if ($User.Enabled -eq $false) {
        Write-Host "User $Username is already DISABLED."
    } else {
        # Disable the -a account of the user
        Disable-ADAccount -Identity $User
        Write-Host "User $Username has been DISABLED."
    }
}