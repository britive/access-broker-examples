# ============================================================
# Rotate/Create Service Admin (sa-) Account with Passphrase
# ============================================================
# Creates or rotates credentials for a user's "sa-" (service admin)
# account via the Britive on-premise broker for Active Directory.
# Generates a memorable passphrase-style password by combining
# English onset clusters with common rimes (e.g. "Blaze-Creed-Stork-Vine42").
#
# Required env vars (injected by Britive):
#   user   – Email address of the requesting user (e.g. jdoe@contoso.com)
#   domain – AD domain suffix for UPN construction (e.g. contoso.com)
#
# Optional env vars:
#   firstName – First name for the AD account
#   lastName  – Last name for the AD account
#   company   – Company attribute for the AD account
#
# The script outputs the credentials in Britive's expected format
# so the platform can surface them to the user upon checkout.
# ============================================================

# ----------------------------------------------------------
# Fail-fast: treat every error as terminating
# ----------------------------------------------------------
$ErrorActionPreference = 'Stop'

try {
    # ----------------------------------------------------------
    # Import Active Directory module
    # ----------------------------------------------------------
    Import-Module ActiveDirectory -ErrorAction Stop

    # ----------------------------------------------------------
    # Read and validate required environment variables
    # ----------------------------------------------------------
    $Email = $env:user
    $Domain = $env:domain

    if (-not $Email) {
        throw "Environment variable 'user' is not set. Cannot identify requesting user."
    }

    if (-not $Domain) {
        throw "Environment variable 'domain' is not set. Cannot construct UPN."
    }

    # Validate email format and extract username prefix
    if ($Email -match '^([^@]+)@') {
        $UsernamePrefix = $matches[1]
    }
    else {
        throw "Invalid email format: $Email. Expected user@domain."
    }

    # Read optional user attributes (used when creating new accounts)
    $FirstName = $env:firstName
    $LastName  = $env:lastName
    $Company   = $env:company

    # ----------------------------------------------------------
    # Build the sa- account identifiers
    # ----------------------------------------------------------
    # SamAccountName: sa-<username> (e.g. sa-jdoe)
    $Username = "sa-$UsernamePrefix"
    # UPN: sa-<username>@<domain> (e.g. sa-jdoe@contoso.com)
    $UserPrincipalName = "$Username@$Domain"

    Write-Output "Processing sa- account: $Username (UPN: $UserPrincipalName)"

    # ----------------------------------------------------------
    # Check if the sa- account already exists in AD
    # ----------------------------------------------------------
    $User = Get-ADUser -Filter "SamAccountName -eq '$Username'" -ErrorAction SilentlyContinue

    # ==========================================================
    # Generate a memorable passphrase password
    # ==========================================================
    # Combines common English onset clusters (bl, cr, st, th…)
    # with common English rimes (-ake, -ight, -one…) to produce
    # pseudo-words that sound natural and are easy to remember.
    # Example output: "Blaze-Creed-Stork-Vine42"
    function New-EnglishWord {
        # Common English consonant onsets (single and clusters)
        $onsets = @(
            "b","bl","br","c","ch","cl","cr","d","dr","f","fl","fr",
            "g","gl","gr","h","j","k","l","m","n","p","pl","pr",
            "r","s","sc","sh","sk","sl","sm","sn","sp","st","str",
            "sw","t","th","tr","tw","v","w","wh","z"
        )

        # Common English rimes (vowel nucleus + coda)
        $rimes = @(
            "ace","ade","aft","age","ail","ain","ake","ale","all","ame",
            "amp","ane","ank","ark","arm","art","ash","ast","ate","awn",
            "aze","ead","eal","eam","ear","eat","eck","eed","eel","een",
            "eep","ell","end","ent","ess","est","ew","ice","ick","ide",
            "ife","ift","ight","ill","ine","ing","ink","ire","isk","ist",
            "ite","ive","oad","oam","oar","oat","ock","ode","oil","oke",
            "old","oll","ome","one","ong","ood","ook","ool","oom","oon",
            "oop","ore","ork","orn","ort","ose","ost","ound","out","ove",
            "ow","own","ub","uck","uff","uge","ull","ump","ung","unk",
            "urn","ush","ust","ute"
        )

        # Pick a random onset + rime and combine
        $onset = $onsets[(Get-Random -Maximum $onsets.Length)]
        $rime  = $rimes[(Get-Random -Maximum $rimes.Length)]

        return $onset + $rime
    }

    # Build the passphrase from multiple English-sounding words
    # separated by dashes for readability (e.g. "Blaze-Creed-Stork-Vine42")
    $words = @()
    $totalLength = 0
    $minLength = 14

    while ($totalLength -lt $minLength) {
        $word = New-EnglishWord
        # Capitalize the first letter
        $word = $word.Substring(0,1).ToUpper() + $word.Substring(1)
        $words += $word
        # Account for word length + dash separator
        $totalLength = ($words -join "-").Length
    }

    $password = ($words -join "-")

    # Append a random 2-digit number for additional complexity
    $password += (Get-Random -Minimum 10 -Maximum 100).ToString()

    $SecurePassword = ConvertTo-SecureString $password -AsPlainText -Force

    # ==========================================================
    # Create or rotate the sa- account
    # ==========================================================
    if (-not $User) {
        # ----------------------------------------------------------
        # Account does not exist — create it
        # ----------------------------------------------------------
        Write-Output "Account '$Username' not found. Creating new account..."

        # Build the New-ADUser parameters with all available attributes
        $newUserParams = @{
            Name              = $Username
            SamAccountName    = $Username
            UserPrincipalName = $UserPrincipalName
            AccountPassword   = $SecurePassword
            Enabled           = $true
            Description       = "Service admin account for $Email"
        }

        # Add optional attributes if provided via environment variables
        if ($FirstName) {
            $newUserParams['GivenName'] = $FirstName
        }
        if ($LastName) {
            $newUserParams['Surname'] = $LastName
        }
        if ($FirstName -and $LastName) {
            $newUserParams['DisplayName'] = "$FirstName $LastName (SA)"
        }
        if ($Company) {
            $newUserParams['Company'] = $Company
        }

        New-ADUser @newUserParams -ErrorAction Stop

        Write-Output "User $Username created and enabled."
        Write-Output "username: $Username"
        Write-Output "password: $password"
    }
    else {
        # ----------------------------------------------------------
        # Account exists — rotate the password and ensure it's enabled
        # ----------------------------------------------------------
        Write-Output "Account '$Username' found. Rotating password..."

        Set-ADAccountPassword -Identity $Username -NewPassword $SecurePassword -Reset -ErrorAction Stop
        Enable-ADAccount -Identity $Username -ErrorAction Stop

        Write-Output "Account $Username has been enabled and the password has been set."
        Write-Output "username: $Username"
        Write-Output "password: $password"
    }
}
catch {
    Write-Error "sa- account rotation FAILED for '$($env:user)': $($_.Exception.Message)"
    exit 1
}
