# Variables (read from environment or prompt if not set)
$serverName   = $env:server_name
$databaseName = $env:database_name
$adminUser    = $env:admin_user
$adminPassword= $env:admin_password
$userEmail    = $env:user_email
$profileName  = $env:profileName

# Log file setup
$logFile = "logs\${profileName}-Checkout.log"

try {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Validate required variables
    if (-not $userEmail) {
        Add-Content -Path $logFile -Value "$timestamp Error: The user_email environment variable is not set."
        exit 1
    }

    $newUser = $userEmail

    # Function to generate a 12-character random password
    function Generate-RandomPassword {
        Add-Type -AssemblyName System.Web
        [System.Web.Security.Membership]::GeneratePassword(16, 4) -replace '[^A-Za-z0-9@#$%^&+=_]', '' -replace '^(.{12}).*$', '$1'
    }

    $newUserPassword = Generate-RandomPassword

    # SQL commands
    $sqlCommandsMaster = @"
CREATE LOGIN [$newUser] WITH PASSWORD = '$newUserPassword';
"@

    $sqlCommandsDatabase = @"
CREATE USER [$newUser] FOR LOGIN [$newUser] WITH DEFAULT_SCHEMA=[db_owner];
ALTER ROLE db_owner ADD MEMBER [$newUser];
"@

    $sqlcmd = "sqlcmd"

    $masterResult = & $sqlcmd -S $serverName -d master -U $adminUser -P $adminPassword -Q $sqlCommandsMaster 2>&1
    Add-Content -Path $logFile -Value "$timestamp Master DB command output:`n$masterResult"
    Add-Content -Path $logFile -Value "$timestamp Created login for user $newUser"

    $dbResult = & $sqlcmd -S $serverName -d $databaseName -U $adminUser -P $adminPassword -Q $sqlCommandsDatabase 2>&1
    Add-Content -Path $logFile -Value "$timestamp Target DB command output:`n$dbResult"
    Add-Content -Path $logFile -Value "$timestamp Created user $newUser in database $databaseName"

    # Output connection info to user (not logged)
    Write-Host ""
    Write-Host "==============================================="
    Write-Host "  Temporary Database Access Details"
    Write-Host "==============================================="
    Write-Host ("{0,-12}: {1}" -f "Server", $serverName)
    Write-Host ("{0,-12}: {1}" -f "Database", $databaseName)
    Write-Host ("{0,-12}: {1}" -f "Username", $newUser)
    Write-Host ("{0,-12}: {1}" -f "Password", $newUserPassword)
    Write-Host "==============================================="
    Write-Host ""
}
catch {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp An error occurred: $_"
}