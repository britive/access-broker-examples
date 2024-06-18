# Install-Module -Name Get-ActiveSession
# https://www.powershellgallery.com/packages/Get-ActiveSession/1.0.4
Import-Module Get-ActiveSession


# Group,Server
# Group A,Server A
# Group B,Server B
# Group B,Server C
$csvFilePath = "C:\Program Files (x86)\Britive Inc\Britive Broker\scripts\mappings.csv"

$user=$env:user
$user_no_domain=$user.Split("@")[0]
$group=$env:group

if (Test-Path $csvFilePath) {
    $csvData = Import-Csv $csvFilePath

    foreach ($record in $csvData) {
        $row_group = $record.Group
        $server = $record.Server

        if ($row_group -eq $group) {
            Start-PSCRemoteLogoff -Name $server -TargetUser $user_no_domain
        }
    }
} else {
    Write-Error "File not found: $csvFilePath"
}

