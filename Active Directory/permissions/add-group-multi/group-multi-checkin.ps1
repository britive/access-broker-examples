# Powershell script example to allow a user to request group memberships for their "-a" account
# via the Britive on-premise broker for Acitve Directory(AD)

# Variables fulfilled by Britive cloud platform upon checkin
$Email = $env:user
$GroupName = $env:group
$Prefix = $env:prefix

# When Britive passes the user name in an email format Strip the username from the email address and append "Prefix"
$Username = ($Email -split "@")[0] + $Prefix


# Check if user exists
$User = Get-ADUser -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

if ($User) {
    # Check if group exists
    $Group = Get-ADGroup -Filter {Name -eq $GroupName} -ErrorAction SilentlyContinue

    if ($Group) {
        # Check if user is in the group
        $IsMember = Get-ADGroupMember -Identity $GroupName -Recursive | Where-Object { $_.SamAccountName -eq $Username }

        if ($IsMember) {
            # Remove user from group - checkin action
            Remove-ADGroupMember -Identity $GroupName -Members $Username -Confirm:$false
            Write-Host "User $Username removed from group $GroupName."
        } else {
            Write-Host "User $Username is not a member of group $GroupName."
        }
    } else {
        Write-Host "Group $GroupName does not exist."
    }
} else {
    Write-Host "User $Username does not exist."
}
