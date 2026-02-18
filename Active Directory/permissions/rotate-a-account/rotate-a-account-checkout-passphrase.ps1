# Powershell script example to rotate credentials for user's "-a" account
# via the Britive on-premise broker for Acitve Directory(AD)
# This version generates memorable passphrase-style passwords

# Variables fulfilled by Britive cloud platform upon checkout
$Email = $env:user

# Strip the username from the email address and append "-a"
$Username = ($Email -split "@")[0] + "-a"

# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

# Generate a memorable passphrase using pronounceable pseudo-words
# Uses consonant-vowel patterns to create easy-to-remember, speakable words
function New-PronounceableWord {
    param([int]$syllables = 2)

    $consonants = "bdfghjklmnprstvwz"
    $vowels = "aeiou"
    $word = ""

    for ($s = 0; $s -lt $syllables; $s++) {
        # Each syllable is consonant + vowel (+ optional consonant for last syllable)
        $word += $consonants[(Get-Random -Maximum $consonants.Length)]
        $word += $vowels[(Get-Random -Maximum $vowels.Length)]
    }
    # Add ending consonant for better word feel
    $word += $consonants[(Get-Random -Maximum $consonants.Length)]

    return $word
}

# Generate passphrase with multiple pronounceable words
$password = ""
$minLength = 18

while ($password.Length -lt $minLength) {
    # Generate a 2-3 syllable word (5-7 chars) and capitalize it
    $syllables = Get-Random -Minimum 2 -Maximum 4
    $word = New-PronounceableWord -syllables $syllables
    $word = $word.Substring(0,1).ToUpper() + $word.Substring(1)
    $password += $word
}

# Add a random 2-digit number at the end for additional complexity
$password += (Get-Random -Minimum 10 -Maximum 100).ToString()

$SecurePassword = ConvertTo-SecureString $password -AsPlainText -Force

if (-not $User) {
    # Create user if it doesn't exist

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
    # Set the password for the user
    Set-ADAccountPassword -Identity $Username -NewPassword $SecurePassword -Reset
    # Enable the account for good measure
    Enable-ADAccount -Identity $Username

    # Share newly rotated credentials with the end user who checkedout the profile
    Write-Output "Account $Username has been enabled and the password has been set."
    Write-Output "username: $Username"
    Write-Output "password: $password"
}
