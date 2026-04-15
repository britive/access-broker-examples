# ============================================================
# Active Directory Account Password Rotation + AWS Secrets Manager Sync
# ============================================================
# Rotates the password for a specified AD account, then updates
# the credential in AWS Secrets Manager so downstream consumers
# stay in sync.
#
# Required env vars:
#   AD_TARGET_USER  – SamAccountName of the account to rotate
#   AD_NEW_PASSWORD – The new password to set on the account
#   AWS_SECRET_ARN  – ARN of the Secrets Manager secret to update
#
# Optional env vars:
#   AWS_SECRET_KEY  – JSON key name that holds the password field
#                     (defaults to "password")
#
# AWS credentials must be available via the standard AWS credential
# chain (instance role, ECS task role, env vars, ~/.aws/credentials).
# The executing identity needs secretsmanager:GetSecretValue and
# secretsmanager:PutSecretValue on the target secret.
#
# Security notes:
#   - AD_NEW_PASSWORD is cleared from the environment immediately after
#     being read so it does not persist in the process environment.
#   - The updated secret JSON is never passed on the CLI (process list
#     visible); it is written to a restricted temp file and referenced
#     via file:// so only the file path appears in the process list.
#   - The temp file and all in-memory sensitive variables are zeroed and
#     removed in a finally block that runs regardless of success/failure.
# ============================================================

$ErrorActionPreference = 'Stop'

# Track the temp file path outside try so finally can always clean it up
$TempSecretFile = $null
$ExitCode       = 0

try {
    # ----------------------------------------------------------
    # Validate required environment variables
    # ----------------------------------------------------------
    if (-not $env:AD_TARGET_USER) {
        throw "AD_TARGET_USER environment variable is not set. Cannot identify target account."
    }

    if (-not $env:AD_NEW_PASSWORD) {
        throw "AD_NEW_PASSWORD environment variable is not set. Cannot rotate password."
    }

    if (-not $env:AWS_SECRET_ARN) {
        throw "AWS_SECRET_ARN environment variable is not set. Cannot update Secrets Manager."
    }

    $TargetUser  = $env:AD_TARGET_USER
    $NewPassword = $env:AD_NEW_PASSWORD
    $SecretArn   = $env:AWS_SECRET_ARN
    $SecretKey   = if ($env:AWS_SECRET_KEY) { $env:AWS_SECRET_KEY } else { "password" }

    # Clear the password from the environment immediately after reading -
    # child processes spawned later (e.g. aws CLI) will not inherit it.
    [System.Environment]::SetEnvironmentVariable('AD_NEW_PASSWORD', $null, 'Process')

    # ----------------------------------------------------------
    # Resolve the AWS CLI path
    # ----------------------------------------------------------
    # The broker service runs as an AD service account whose PATH
    # may not include the AWS CLI install directory. Look up the
    # full path from the system-wide Program Files location and
    # from the Machine-level PATH so the script works regardless
    # of which account executes it.
    $AwsCli = Get-Command aws -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty Source -First 1

    if (-not $AwsCli) {
        # Check well-known install locations
        $candidates = @(
            "$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe",
            "${env:ProgramFiles(x86)}\Amazon\AWSCLIV2\aws.exe",
            "C:\Program Files\Amazon\AWSCLIV2\aws.exe",
            "C:\Program Files (x86)\Amazon\AWSCLIV2\aws.exe"
        )
        foreach ($path in $candidates) {
            if (Test-Path $path) { $AwsCli = $path; break }
        }
    }

    if (-not $AwsCli) {
        throw "AWS CLI not found. Install it or set its directory in the system PATH."
    }

    Write-Host "Using AWS CLI: $AwsCli"
    Write-Host "Starting password rotation for user: $TargetUser"
    Write-Host "Target secret ARN: $SecretArn"

    # ----------------------------------------------------------
    # Import the Active Directory module
    # ----------------------------------------------------------
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "ActiveDirectory module loaded."

    # ----------------------------------------------------------
    # Verify the target user exists in AD before attempting reset
    # ----------------------------------------------------------
    $adUser = Get-ADUser -Identity $TargetUser -ErrorAction Stop
    Write-Host "Confirmed user exists: $($adUser.SamAccountName)"

    # ----------------------------------------------------------
    # Convert the new password to a SecureString and reset
    # ----------------------------------------------------------
    $SecurePass = ConvertTo-SecureString $NewPassword -AsPlainText -Force

    Set-ADAccountPassword `
        -Identity $TargetUser `
        -NewPassword $SecurePass `
        -Reset `
        -ErrorAction Stop

    Write-Host "AD password updated successfully."

    # ----------------------------------------------------------
    # Unlock the account and disable forced password change
    # ----------------------------------------------------------
    Unlock-ADAccount -Identity $TargetUser -ErrorAction SilentlyContinue
    Set-ADUser -Identity $TargetUser -ChangePasswordAtLogon $false -ErrorAction Stop

    Write-Host "Account unlocked and password-change-at-logon disabled."

    # ----------------------------------------------------------
    # Update AWS Secrets Manager
    # Fetch the existing secret, patch the password key, and write
    # it back so all other fields (username, host, etc.) are kept.
    # ----------------------------------------------------------
    Write-Host "Fetching current secret value from Secrets Manager..."

    $getResult = & $AwsCli secretsmanager get-secret-value `
        --secret-id $SecretArn `
        --query SecretString `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to retrieve secret from Secrets Manager: $getResult"
    }

    # Parse the JSON secret, update the password field, re-serialize.
    # PowerShell 5.1's ConvertTo-Json escapes <, >, &, ' as \uXXXX
    # sequences (e.g. < becomes \u003c). We unescape them so the
    # password is stored verbatim in Secrets Manager.
    $secretObj = $getResult | ConvertFrom-Json
    $secretObj.$SecretKey = $NewPassword
    $updatedSecret = $secretObj | ConvertTo-Json -Compress
    $updatedSecret = [Regex]::Replace($updatedSecret, '\\u([0-9A-Fa-f]{4})', {
        param($match)
        [char][int]"0x$($match.Groups[1].Value)"
    })

    # ----------------------------------------------------------
    # Write the updated secret JSON to a restricted temp file.
    # Passing --secret-string directly on the command line would
    # expose the plaintext password in the OS process list.
    # ----------------------------------------------------------
    $TempSecretFile = [System.IO.Path]::GetTempFileName()

    # Restrict the file to the current user only (Owner: FullControl, no inheritance)
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, remove inherited rules
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $currentUser,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.SetAccessRule($rule)
    Set-Acl -Path $TempSecretFile -AclObject $acl

    # Use UTF-8 WITHOUT BOM. The default [System.Text.Encoding]::UTF8
    # includes a BOM (EF BB BF) which prepends garbage chars to the
    # JSON and breaks parsing in AWS Secrets Manager.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($TempSecretFile, $updatedSecret, $utf8NoBom)

    Write-Host "Updating secret in Secrets Manager (key: '$SecretKey')..."

    $putResult = & $AwsCli secretsmanager put-secret-value `
        --secret-id $SecretArn `
        --secret-string "file://$TempSecretFile" 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update secret in Secrets Manager: $putResult"
    }

    Write-Host "Secrets Manager updated successfully."
    Write-Host "Password rotation completed successfully for user: $TargetUser"
}
catch {
    Write-Error "Password rotation FAILED for user '$TargetUser': $($_.Exception.Message)"
    $ExitCode = 1
}
finally {
    # ----------------------------------------------------------
    # Always clean up - runs on success, failure, and termination
    # ----------------------------------------------------------

    # Overwrite the temp file with zeros before deleting to prevent
    # recovery from the filesystem, then remove it.
    if ($TempSecretFile -and (Test-Path $TempSecretFile)) {
        try {
            $fileLen = (Get-Item $TempSecretFile).Length
            if ($fileLen -gt 0) {
                $zeros = New-Object byte[] $fileLen
                [System.IO.File]::WriteAllBytes($TempSecretFile, $zeros)
            }
        } catch { <# best-effort overwrite #> }
        Remove-Item -Path $TempSecretFile -Force -ErrorAction SilentlyContinue
    }

    # Dispose the SecureString to release protected memory
    if ($SecurePass -is [System.Security.SecureString]) {
        $SecurePass.Dispose()
    }

    # Zero out sensitive string variables in the current scope
    foreach ($varName in @('NewPassword', 'updatedSecret', 'getResult')) {
        if (Get-Variable -Name $varName -ErrorAction SilentlyContinue) {
            Set-Variable -Name $varName -Value ([string]::Empty)
            Remove-Variable -Name $varName -ErrorAction SilentlyContinue
        }
    }

    # Ensure the password env var is cleared even if the script threw
    # before reaching the earlier explicit clear
    [System.Environment]::SetEnvironmentVariable('AD_NEW_PASSWORD', $null, 'Process')

    Write-Host "Sensitive variables and temp files cleared."
}

exit $ExitCode
