# Powershell script example to rotate credentials for user's "-a" account
# via the Britive on-premise broker for Active Directory(AD)
# This script rotates the password upon check-in WITHOUT sharing/outputting the new password

# Import Active Directory module
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "Failed to import ActiveDirectory module: $_"
    exit 1
}

# Variables fulfilled by Britive cloud platform upon check-in
$Email = $env:user
$Domain = $env:domain

# Validate that required environment variable is set
if (-not $Email) {
    Write-Error "Environment variable 'user' is not set."
    exit 1
}

# Validate email format and extract username prefix
if ($Email -match '^([^@]+)@') {
    $UsernamePrefix = $matches[1]
    Write-Output "Extracted username prefix: $UsernamePrefix"
} else {
    Write-Error "Invalid email format: $Email"
    exit 1
}

# Strip the username from the email address and append "sa-" prefix
$Username = "sa-$UsernamePrefix"  # SamAccountName
$UserPrincipalName = "$Username@$Domain"  # UPN with domain

# Function to generate a random password with guaranteed character complexity
function New-RandomPassword {
    param(
        [int]$Length = 12
    )
    $upperChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lowerChars = 'abcdefghijklmnopqrstuvwxyz'
    $numberChars = '0123456789'
    $specialChars = '!@#$%^&*()_+-=[]{}|;:,.<>?/~'

    # Ensure at least one of each character type for password policy compliance
    $password = @()
    $password += $upperChars[(Get-Random -Maximum $upperChars.Length)]
    $password += $lowerChars[(Get-Random -Maximum $lowerChars.Length)]
    $password += $numberChars[(Get-Random -Maximum $numberChars.Length)]
    $password += $specialChars[(Get-Random -Maximum $specialChars.Length)]

    # Fill the rest randomly
    $allChars = $upperChars + $lowerChars + $numberChars + $specialChars
    for ($i = $password.Count; $i -lt $Length; $i++) {
        $password += $allChars[(Get-Random -Maximum $allChars.Length)]
    }

    # Shuffle the password to avoid predictable patterns
    $password = $password | Get-Random -Count $password.Count

    return -join $password
}

# Check if user exists by BOTH SamAccountName and UserPrincipalName
# This prevents issues where the account exists with different UPN
try {
    $User = Get-ADUser -Filter "SamAccountName -eq '$Username' -or UserPrincipalName -eq '$UserPrincipalName'" -ErrorAction SilentlyContinue
} catch {
    Write-Error "Error querying Active Directory for user '$Username': $_"
    exit 1
}

# Generate a new password based on policy constraints
$password = New-RandomPassword -Length 12
$SecurePassword = ConvertTo-SecureString $password -AsPlainText -Force


if (-not $User) {
    # The user account does not exist and hence no action required upon check-in
    Write-Output "User '$Username' does not exist. No password rotation performed."
} else {
    # User exists - rotate the password upon check-in
    # NOTE: Password is NOT shared or output anywhere for security reasons
    Write-Output "User '$Username' found in Active Directory. Rotating password..."

    try {
        # Set the password for the user upon check-in
        Set-ADAccountPassword -Identity $Username -NewPassword $SecurePassword -Reset -ErrorAction Stop
        Write-Output "Password for account '$Username' has been rotated successfully."
        # IMPORTANT: Do NOT output the password - this is a security measure for check-in
    } catch {
        Write-Error "Failed to reset password for user '$Username': $_"
        exit 1
    }
}

# Clear password variables from memory for security
$password = $null
$SecurePassword = $null