# ============================================================
# Britive Broker → AWS Secrets Manager Secret Synchronization
# ============================================================
# Writes a secret value to AWS Secrets Manager.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Compatible with both Windows PowerShell 5.1 and
# PowerShell Core 7+ (cross-platform).
#
# Prerequisites:
#   - AWS CLI v2 installed and on PATH
#   - AWS credentials available via env vars, instance profile,
#     IRSA, or a named profile (AWS_PROFILE)
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE       – The secret value to write
#   AWS_SECRET_NAME    – Name or ARN of the target secret in
#                        AWS Secrets Manager
#   AWS_REGION         – AWS region where the secret lives
#
# Optional env vars:
#   AWS_PROFILE        – Named AWS CLI profile to use
# ============================================================

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$ts] $Message"
}

try {
    # ----------------------------------------------------------
    # Validate required environment variables
    # ----------------------------------------------------------
    Write-Log "Validating environment variables..."

    if (-not $env:SECRET_VALUE)    { throw "SECRET_VALUE is not set."    }
    if (-not $env:AWS_SECRET_NAME) { throw "AWS_SECRET_NAME is not set." }
    if (-not $env:AWS_REGION)      { throw "AWS_REGION is not set."      }

    $SecretValue   = $env:SECRET_VALUE
    $AwsSecretName = $env:AWS_SECRET_NAME
    $AwsRegion     = $env:AWS_REGION
    $AwsProfile    = $env:AWS_PROFILE

    Write-Log "Target AWS secret : $AwsSecretName"
    Write-Log "AWS region        : $AwsRegion"

    # ----------------------------------------------------------
    # Write secret value to a locked-down temp file.
    # AWS CLI supports `file://` references for --secret-string,
    # which avoids the value appearing as a visible process
    # argument. The finally block ensures cleanup on any exit.
    # ----------------------------------------------------------
    $TmpFile = [System.IO.Path]::GetTempFileName()
    try {
        # Restrict permissions on the temp file before writing
        if ($IsWindows -or ($PSVersionTable.PSVersion.Major -lt 6)) {
            $Acl = Get-Acl $TmpFile
            $Acl.SetAccessRuleProtection($true, $false)
            $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl', 'Allow'
            )
            $Acl.AddAccessRule($Rule)
            Set-Acl $TmpFile $Acl
        } else {
            # Unix: chmod 600
            & chmod 600 $TmpFile
        }

        # Write secret without trailing newline
        [System.IO.File]::WriteAllText($TmpFile, $SecretValue, (New-Object System.Text.UTF8Encoding $false))

        # ----------------------------------------------------------
        # Write secret to AWS Secrets Manager using file:// reference
        # ----------------------------------------------------------
        Write-Log "Writing secret to AWS Secrets Manager..."

        $AwsArgs = @(
            'secretsmanager', 'put-secret-value',
            '--region',        $AwsRegion,
            '--secret-id',     $AwsSecretName,
            '--secret-string', "file://$TmpFile",
            '--output',        'json'
        )
        if ($AwsProfile) { $AwsArgs = @('--profile', $AwsProfile) + $AwsArgs }

        $Result = & aws @AwsArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "put-secret-value failed — attempting create-secret..."

            $CreateArgs = @(
                'secretsmanager', 'create-secret',
                '--region',        $AwsRegion,
                '--name',          $AwsSecretName,
                '--secret-string', "file://$TmpFile",
                '--output',        'json'
            )
            if ($AwsProfile) { $CreateArgs = @('--profile', $AwsProfile) + $CreateArgs }

            $Result = & aws @CreateArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to write secret '$AwsSecretName' to AWS Secrets Manager."
            }
            Write-Log "Secret created successfully."
        } else {
            Write-Log "Secret updated successfully."
        }
    } finally {
        # Always remove the temp file, even on error
        if (Test-Path $TmpFile) { Remove-Item $TmpFile -Force -ErrorAction SilentlyContinue }
    }

    Write-Log "Sync complete: secret written to AWS Secrets Manager '$AwsSecretName'."
    exit 0
}
catch {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Error "[$ts] FAILED: $($_.Exception.Message)"
    exit 1
}
