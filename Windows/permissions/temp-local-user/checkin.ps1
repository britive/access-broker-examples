 $email=$env:email
$username=$email.Split('@')[0]
$user=$username -replace '[^a-zA-Z0-9]', ''
$killrdp=if ($env:killrdp) { $env:killrdp } else { "0" }

# above is added from agent

if ($user -eq $null) {
	return $false
}

# Function to kill active RDP sessions for a given user
function Kill-RDPSessions {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Username
    )

    try {
        $qwinstaOutput=qwinsta $Username
        $lines = $qwinstaOutput -split "`r`n"
        $userLines = $lines | Where-Object { $_ -match "\b$Username\b" }
        $sessionIds = $userLines | ForEach-Object {
                $fields = $_ -split '\s+'
                if ($fields.Count -ge 3) {
                    $fields[3]
                }
            }
    }
    catch {
        $sessionIds = @()
    }

    foreach ($session in $sessionIds) {
        Invoke-RDUserLogoff -HostServer localhost -UnifiedSessionID $session -Force
    }
}

# Function to remove a local user from the machine
function CleanUp-LocalUser {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Username
    )

    try {
        # Get the local user object
        $user = Get-LocalUser -Name $Username -ErrorAction Stop

        # Remove the local user
        Write-Output "Removing local user: $Username"
        $user | Remove-LocalUser -ErrorAction Stop
    }
    catch {
        Write-Error "Error removing local user: $_"
    }
}


if ($killrdp -eq "1") {
	# Kill active RDP sessions for the user
    Kill-RDPSessions -Username $user
}


# Remove the local user
CleanUp-LocalUser -Username $user

