
Param()

$asHost = $env:AS400_HOST
$adminUser = $env:AS400_ADMIN_USER
$adminPass = $env:AS400_ADMIN_PASS
$newUser = $env:AS400_NEW_USER
$userDesc = $env:AS400_NEW_USER_DESC
$action = $env:AS400_ACTION

function generatePassword($length = 12) {
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()'
    -join ((1..$length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

if ($action -eq "checkout") {
    $newPass = generatePassword
    Write-Host "Generated password for $newUser : $newPass"

    & system -host $asHost -user $adminUser -password $adminPass -command "CRTUSRPRF USRPRF($newUser) PASSWORD($newPass) TEXT('$userDesc')"
}
elseif ($action -eq "checkin") {
    & system -host $asHost -user $adminUser -password $adminPass -command "DLTUSRPRF USRPRF($newUser) OWNOBJOPT(*DLT)"
}
else {
    Write-Error "Invalid action. Use 'create' or 'remove'."
}
