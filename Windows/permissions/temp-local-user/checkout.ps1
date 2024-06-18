$email=$env:email
$username=$email.Split('@')[0]
$user=$username -replace '[^a-zA-Z0-9]', ''
$group=$env:group


# above is added from agent
if ($user -eq $null -or $group -eq $null) {
	return $false
}

# Define the length of the password
$length = 12

# Define characters to be used in the password
$chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_-+=[]{}|;:,.<>?/~"

# Generate the password
$password = ""
for ($i = 0; $i -lt $length; $i++) {
    $password += $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)]
}
$userencpass = ConvertTo-SecureString -String $password -AsPlainText -Force

$LocalUser = Get-LocalUser -Name $user -ErrorAction SilentlyContinue

if ($LocalUser) {
    # User exists, set new password
    Write-Error "Setting new password for existing user: $user"
    $LocalUser | Set-LocalUser -Password $userencpass
}
else {
    # User does not exist, create new user
    Write-Error "Creating new local user: $user"
    New-LocalUser -Name $user -Password $userencpass | Out-Null
}

# $result=New-LocalUser -name $user -password $userencpass

Add-LocalGroupMember -group $group -member $user
Write-Output "username:s:$user"
Write-Output "password:s:$password"