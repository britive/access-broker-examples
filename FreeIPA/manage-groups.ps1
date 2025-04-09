<#
This script allows you to manage ephemeral group memberships with FreeIPA.
The suer and group information made available in the script via the Britive checkout process is used to add or remove users from groups.
The script requires the Manage-FreeIPA module to be installed and available in the PowerShell session.
The script takes the following parameters:
- Server: The FreeIPA server to connect to.
- Username: The username to authenticate with.
- Password: The password to authenticate with.
- User: The user to be added or removed from the group.
- Group: The group to which the user will be added or removed.
- Action: The action to perform, either "Checkout" or "Checkin".
The script will connect to the FreeIPA server, check if the user and group exist, and then perform the specified action
#>
param (
    [Parameter(Mandatory)]
    [string]$Server,

    [Parameter(Mandatory)]
    [string]$Username,

    [Parameter(Mandatory)]
    [string]$Password,

    [Parameter(Mandatory)]
    [string]$User,

    [Parameter(Mandatory)]
    [string]$Group,

    [Parameter(Mandatory)]
    [ValidateSet("checkout", "checkin")]
    [string]$Action
)

function Write-ErrorAndExit {
    param (
        [string]$Message,
        [int]$Code = 1
    )
    Write-Error $Message
    exit $Code
}

try {
    Import-Module Manage-FreeIPA -ErrorAction Stop

    Connect-FreeIPA -Server $Server -Username $Username -Password $Password -ErrorAction Stop

    $user = Get-FreeIPAUser -Identity $User -ErrorAction Stop
} catch {
    Write-ErrorAndExit "User '$User' not found or failed to connect to FreeIPA. $_" 2
}

try {
    $group = Get-FreeIPAGroup -Identity $Group -ErrorAction Stop
} catch {
    Write-ErrorAndExit "Group '$Group' not found. $_" 3
}

try {
    if ($Action -eq "checkout") {
        Add-FreeIPAGroupMember -Identity $Group -User $User -ErrorAction Stop
        Write-Output "User '$User' added to group '$Group'."
    } elseif ($Action -eq "checkin") {
        Remove-FreeIPAGroupMember -Identity $Group -User $User -ErrorAction Stop
        Write-Output "User '$User' removed from group '$Group'."
    }
    exit 0
} catch {
    Write-ErrorAndExit "Failed to $Action user '$User' in group '$Group'. $_" 4
}

