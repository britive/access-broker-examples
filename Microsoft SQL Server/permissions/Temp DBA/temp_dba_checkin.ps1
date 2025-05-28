# Variables (set directly or via environment)
$serverName = $env:server_name
$databaseName = $env:database_name
$adminUser = $env:admin_user
$adminPassword = $env:admin_password
$userEmail = $env:user_email
$profileName = $env:profileName

# Log file setup
$logFile = "logs\${profileName}-Checkin.log"

try {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Validate required variables
    if (-not $userEmail) {
        Add-Content -Path $logFile -Value "$timestamp Error: The user_email environment variable is not set."
        exit 1
    }

    # Extract username from email
    $userToDelete = $userEmail

    # SQL commands to drop user and login
    $sqlCommandsDatabase = @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$userToDelete')
    DROP USER [$userToDelete];
"@

    $sqlCommandsMaster = @"
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$userToDelete')
    DROP LOGIN [$userToDelete];
"@

    $sqlcmd = "sqlcmd"

    $dbResult = & $sqlcmd -S $serverName -d $databaseName -U $adminUser -P $adminPassword -Q $sqlCommandsDatabase 2>&1
    Add-Content -Path $logFile -Value "$timestamp Dropped user [$userToDelete] from database [$databaseName]. Result:`n$dbResult"

    $loginResult = & $sqlcmd -S $serverName -d master -U $adminUser -P $adminPassword -Q $sqlCommandsMaster 2>&1
    Add-Content -Path $logFile -Value "$timestamp Dropped login [$userToDelete] from server. Result:`n$loginResult"

    Write-Host "Check-in complete for user $userToDelete."
}
catch {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp An error occurred: $_"
}