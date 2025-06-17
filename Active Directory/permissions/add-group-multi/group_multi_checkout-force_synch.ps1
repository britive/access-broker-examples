## Beta Version - YET TO BE TESTED
<#
.SYNOPSIS
    Britive broker helper — creates “‑a” user (if needed) and adds it to a target
    group on two domain controllers (on‑prem + cloud), forcing immediate replication.

.NOTES
    Requires RSAT AD module and rights to create users / modify group membership.
#>

# Environment variables supplied by Britive
$Email     = $env:user
$GroupName = $env:group
$Prefix    = $env:prefix

# ---------------------------------------------------------------------------
# ❶ Target Domain Controllers (edit the FQDNs to match your environment)
# ---------------------------------------------------------------------------
$DomainControllers = @(
    'onprem‑dc01.contoso.local',  # Primary / on‑prem
    'cloud‑dc01.contoso.local'    # Secondary / cloud
)

$PrimaryDC    = $DomainControllers[0]
$ReplicaDCs   = $DomainControllers[1..($DomainControllers.Count - 1)]

# ---------------------------------------------------------------------------
# ❷ Strip username from email, append prefix (e.g. “‑a”)
# ---------------------------------------------------------------------------
$Username = ($Email -split '@')[0] + $Prefix

# ---------------------------------------------------------------------------
# ❸ Find or create the user (PRIMARY DC ONLY)
# ---------------------------------------------------------------------------
$User = Get-ADUser -Server $PrimaryDC -Filter {SamAccountName -eq $Username} -ErrorAction SilentlyContinue

if (-not $User) {
    # ---- Generate a random 12‑char complex password
    $Length = 12
    $Chars  = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_-+=[]{}|;:,.<>?/~'
    $Password = -join ((1..$Length) | ForEach-Object { $Chars[Get-Random -Minimum 0 -Maximum $Chars.Length] })
    $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force

    New-ADUser -Server $PrimaryDC `
               -Name $Username `
               -SamAccountName $Username `
               -UserPrincipalName $Email `
               -AccountPassword $SecurePassword `
               -Enabled $true

    Write-Output "[$PrimaryDC] User $Username created."

    # ---- Force immediate replication of the new user object to the other DC(s)
    foreach ($dc in $ReplicaDCs) {
        Sync-ADObject -Object $Username -Source $PrimaryDC -Destination $dc -PassThru | Out-Null
        Write-Output "[Sync] Replicated user $Username to $dc."
    }

    # Refresh $User so we have its GUID for later (optional)
    $User = Get-ADUser -Server $PrimaryDC -Identity $Username
}
else {
    Write-Output "[$PrimaryDC] User $Username already exists."
}

# ---------------------------------------------------------------------------
# ❹ Add user to the group (PRIMARY DC), then replicate that change
# ---------------------------------------------------------------------------
$Group = Get-ADGroup -Server $PrimaryDC -Filter {Name -eq $GroupName} -ErrorAction SilentlyContinue

if ($Group) {
    Add-ADGroupMember -Server $PrimaryDC -Identity $GroupName -Members $Username -ErrorAction Stop
    Write-Output "[$PrimaryDC] Added $Username to $GroupName."

    foreach ($dc in $ReplicaDCs) {
        Sync-ADObject -Object $Group.ObjectGuid -Source $PrimaryDC -Destination $dc -PassThru | Out-Null
        Write-Output "[Sync] Replicated group $GroupName membership to $dc."
    }
}
else {
    Write-Warning "[$PrimaryDC] Group $GroupName does not exist."
}

# ---------------------------------------------------------------------------
# ‼️ ALTERNATIVE for separate, non‑replicating forests
# ---------------------------------------------------------------------------
# If your cloud DC is *not* in the same replication scope, comment out the
# Sync‑ADObject loops above and instead run Add‑ADGroupMember *again* for each
# $ReplicaDC using -Server $dc. That will directly write the change in both forests.
