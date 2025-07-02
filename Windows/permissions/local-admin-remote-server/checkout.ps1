# Parse the variables
$UserUPN = $env:user            # e.g., "jdoe@net.domain.com
$TargetComputer = $env:target   # e.g., "server01.net.domain.com" or "server02.net.domain.com"
$TargetGroup = $env:group       # e.g., "Remote Desktop Users" or "Administrators"

# Command to run on remote computer
$scriptBlock = {
    param($RemoteUser, $GroupName)
    try {
        Add-LocalGroupMember -Group $GroupName -Member $RemoteUser -ErrorAction Stop
        Write-Output "User $RemoteUser added to group $GroupName"
    } catch {
        Write-Error "Failed to add user ${RemoteUser} to group ${GroupName}: $($_.Exception.Message)"
    }
}

# Invoke on remote computer
Invoke-Command -ComputerName $TargetComputer -ScriptBlock $scriptBlock -ArgumentList $UserUPN, $TargetGroup
