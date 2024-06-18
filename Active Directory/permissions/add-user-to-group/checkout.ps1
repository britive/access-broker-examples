 # Get user and group names from environment variables
$userName = $env:user
$groupName = $env:group

# Ensure environment variables are set
if (-not $userName) {
    Write-Error "Environment variable user is not set."
    exit 1
}

if (-not $groupName) {
    Write-Error "Environment variable group is not set."
    exit 1
}

# Import Active Directory module
Import-Module ActiveDirectory

# Function to add user to group
function Add-UserToGroup {
    param (
        [string]$user,
        [string]$group
    )

    try {
        # Check if the user exists
        $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$user'" -ErrorAction Stop
    }
    catch {
        Write-Error "The user '$user' does not exist in Active Directory."
        exit 1
    }

    try {
        # Check if the group exists
        $adGroup = Get-ADGroup -Identity $group -ErrorAction Stop
    }
    catch {
        Write-Error "The group '$group' does not exist in Active Directory."
        exit 1
    }

    try {
        # Add the user to the group
        Add-ADGroupMember -Identity $group -Members $adUser -ErrorAction Stop
        Write-Output "User '$user' has been successfully added to group '$group'."
    }
    catch {
        Write-Error "Failed to add user '$user' to group '$group'. Error: $_"
        exit 1
    }
}

# Call the function to add user to group
Add-UserToGroup -user $userName -group $groupName
