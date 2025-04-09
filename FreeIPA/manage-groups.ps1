param (
    [Parameter(Mandatory)]
    [string]$Server,

    [Parameter(Mandatory)]
    [string]$Username,

    [Parameter(Mandatory)]
    [string]$Password,

    [Parameter(Mandatory)]
    [string]$TargetUser,

    [Parameter(Mandatory)]
    [string]$TargetGroup,

    [Parameter(Mandatory)]
    [ValidateSet("Add", "Remove")]
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

    $user = Get-FreeIPAUser -Identity $TargetUser -ErrorAction Stop
} catch {
    Write-ErrorAndExit "User '$TargetUser' not found or failed to connect to FreeIPA. $_" 2
}

try {
    $group = Get-FreeIPAGroup -Identity $TargetGroup -ErrorAction Stop
} catch {
    Write-ErrorAndExit "Group '$TargetGroup' not found. $_" 3
}

try {
    if ($Action -eq "Add") {
        Add-FreeIPAGroupMember -Identity $TargetGroup -User $TargetUser -ErrorAction Stop
        Write-Output "User '$TargetUser' added to group '$TargetGroup'."
    } elseif ($Action -eq "Remove") {
        Remove-FreeIPAGroupMember -Identity $TargetGroup -User $TargetUser -ErrorAction Stop
        Write-Output "User '$TargetUser' removed from group '$TargetGroup'."
    }
    exit 0
} catch {
    Write-ErrorAndExit "Failed to $Action user '$TargetUser' in group '$TargetGroup'. $_" 4
}

