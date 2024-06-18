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
function Remove-UserFromGroup {
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
        Remove-ADGroupMember -Identity $group -Members $adUser -ErrorAction Stop -Confirm:$false
        Write-Output "User '$user' has been successfully removed from group '$group'."
    }
    catch {
        Write-Error "Failed to remove user '$user' from group '$group'. Error: $_"
        exit 1
    }
}

# Call the function to add user to group
Remove-UserFromGroup -user $userName -group $groupName
