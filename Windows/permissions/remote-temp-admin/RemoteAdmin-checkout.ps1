# Parse the variables
$UserName = $env:email.Split('@')[0].Split('-')[0]
$Domain = $env:domain
$TargetComputer = $env:target
$FullUser = "$UserName@$Domain"


# Command to run on remote computer
$scriptBlock = {
    param($RemoteUser)
    try {
        Add-LocalGroupMember -Group "Administrators" -Member $RemoteUser -ErrorAction Stop
        Write-Output "User $RemoteUser added to Administrators group"
    } catch {
        Write-Error "Failed to add user ${RemoteUser}: $($_.Exception.Message)"
    }
}

# Invoke on remote computer
Invoke-Command -ComputerName $TargetComputer -ScriptBlock $scriptBlock -ArgumentList $FullUser
