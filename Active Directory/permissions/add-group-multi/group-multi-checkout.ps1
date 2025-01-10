# Powershell script example to allow a user to request group memberships for their "-a" account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkout

$Email = $env:user
$GroupName = $env:group     

# Strip the username from the email address and append "-a"
$Username = ($Email -split "@")[0] + "-a"

# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

if (-not $User) {
    # Create user if it doesn't exist, this allows for first time users to 
    # not wait for additional admin action to create a "-a" account
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

    New-ADUser -Name $Username -SamAccountName $Username -UserPrincipalName $Email -AccountPassword $SecurePassword -Enabled $true
    Write-Output "User $Username created."
} else {
    Write-Output "User $Username already exists."
}

# Check if group exists
$Group = Get-ADGroup -Filter {Name -eq $GroupName} -ErrorAction SilentlyContinue

if ($Group) {
    # Add user to group
    Add-ADGroupMember -Identity $GroupName -Members $Username
    Write-Output "User $Username added to group $GroupName."
} else {
    Write-Host "Group $GroupName does not exist."
}
