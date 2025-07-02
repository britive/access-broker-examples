# Parse the variables
$UserUPN = $env:user
$TargetComputer = $env:target
$TargetGroup = $env:group   # e.g., "Remote Desktop Users" or "Administrators"

# Command to run on remote computer
$scriptBlock = {
    param($RemoteUser, $GroupName)
    try {
        Remove-LocalGroupMember -Group $GroupName -Member $RemoteUser -ErrorAction Stop
        Write-Output "User $RemoteUser removed from group $GroupName"
    } catch {
        Write-Error "Failed to remove user ${RemoteUser} to group ${GroupName}: $($_.Exception.Message)"
    }
}

# Invoke on remote computer
Invoke-Command -ComputerName $TargetComputer -ScriptBlock $scriptBlock -ArgumentList $UserUPN, $TargetGroup
