# ============================================================
# Britive Broker → GCP Secret Manager Secret Synchronization
# ============================================================
# Adds a new version to a GCP Secret Manager secret.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script — no API
# calls back to Britive are needed.
#
# Authenticates to GCP using a service account key file or a
# pre-obtained access token.  On GCE/GKE/Cloud Run, leave
# auth vars unset to use the instance metadata server.
#
# Compatible with both Windows PowerShell 5.1 and
# PowerShell Core 7+ (cross-platform).
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE        – The secret value to write
#   GCP_PROJECT_ID      – GCP project ID
#   GCP_SECRET_NAME     – Secret name in Secret Manager
#
# Authentication (choose one):
#   GCP_SA_KEY_FILE     – Path to service account JSON key file
#   GCP_ACCESS_TOKEN    – Pre-obtained OAuth2 access token
#                         (leave both unset on GCE/GKE to use
#                          the instance metadata server)
#
# Optional env vars:
#   GCP_DISABLE_PREVIOUS_VERSIONS – Set to "true" to disable all
#                                   previous versions after sync
# ============================================================

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$ts] $Message"
}

function Get-GcpTokenFromSaKey {
    param([string]$KeyFile)

    if (-not (Test-Path $KeyFile)) { throw "GCP_SA_KEY_FILE not found: $KeyFile" }

    $KeyData     = Get-Content $KeyFile -Raw | ConvertFrom-Json
    $ClientEmail = $KeyData.client_email
    $PrivateKey  = $KeyData.private_key

    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $Exp = $Now + 3600

    $Header = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}')
    ).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    $ClaimsJson = @{
        iss   = $ClientEmail
        scope = 'https://www.googleapis.com/auth/cloud-platform'
        aud   = 'https://oauth2.googleapis.com/token'
        iat   = $Now
        exp   = $Exp
    } | ConvertTo-Json -Compress

    $Claims = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes($ClaimsJson)
    ).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    $SigningInput = "$Header.$Claims"

    $Rsa = [System.Security.Cryptography.RSA]::Create()
    $PemContent = $PrivateKey -replace '-----.*?-----' -replace '\s', ''
    $Rsa.ImportPkcs8PrivateKey([Convert]::FromBase64String($PemContent), [ref]$null)

    $SigBytes = $Rsa.SignData(
        [System.Text.Encoding]::UTF8.GetBytes($SigningInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )

    $Signature = [Convert]::ToBase64String($SigBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $Jwt = "$SigningInput.$Signature"

    $TokenResponse = Invoke-RestMethod `
        -Uri         'https://oauth2.googleapis.com/token' `
        -Method      POST `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=$Jwt" `
        -TimeoutSec  15

    return $TokenResponse.access_token
}

try {
    # ----------------------------------------------------------
    # Validate required environment variables
    # ----------------------------------------------------------
    Write-Log "Validating environment variables..."

    if (-not $env:SECRET_VALUE)    { throw "SECRET_VALUE is not set."    }
    if (-not $env:GCP_PROJECT_ID)  { throw "GCP_PROJECT_ID is not set."  }
    if (-not $env:GCP_SECRET_NAME) { throw "GCP_SECRET_NAME is not set." }

    $SecretValue    = $env:SECRET_VALUE
    $GcpProjectId   = $env:GCP_PROJECT_ID
    $GcpSecretName  = $env:GCP_SECRET_NAME
    $SmBase         = 'https://secretmanager.googleapis.com/v1'
    $SecretResource = "projects/$GcpProjectId/secrets/$GcpSecretName"

    Write-Log "GCP project    : $GcpProjectId"
    Write-Log "GCP secret     : $GcpSecretName"

    # ----------------------------------------------------------
    # Obtain GCP access token
    # ----------------------------------------------------------
    if ($env:GCP_ACCESS_TOKEN) {
        $AccessToken = $env:GCP_ACCESS_TOKEN
        Write-Log "Using provided GCP_ACCESS_TOKEN."
    } elseif ($env:GCP_SA_KEY_FILE) {
        Write-Log "Generating access token from service account key..."
        $AccessToken = Get-GcpTokenFromSaKey -KeyFile $env:GCP_SA_KEY_FILE
        Write-Log "Access token obtained (not logged)."
    } else {
        Write-Log "Fetching access token from instance metadata server..."
        $MetaResponse = Invoke-RestMethod `
            -Uri        'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' `
            -Headers    @{ 'Metadata-Flavor' = 'Google' } `
            -TimeoutSec 5
        $AccessToken = $MetaResponse.access_token
        Write-Log "Access token obtained from metadata server."
    }

    if ([string]::IsNullOrEmpty($AccessToken)) { throw "GCP access token is empty." }

    $GcpHeaders = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
    }

    # ----------------------------------------------------------
    # Ensure the GCP secret resource exists; create if not
    # ----------------------------------------------------------
    Write-Log "Checking if secret '$GcpSecretName' exists..."

    try {
        Invoke-RestMethod -Uri "$SmBase/$SecretResource" -Headers $GcpHeaders -TimeoutSec 15 | Out-Null
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Log "Secret not found — creating it..."
            Invoke-RestMethod `
                -Uri        "$SmBase/projects/$GcpProjectId/secrets?secretId=$GcpSecretName" `
                -Method     POST `
                -Headers    $GcpHeaders `
                -Body       '{"replication": {"automatic": {}}}' `
                -TimeoutSec 15 | Out-Null
            Write-Log "Secret created."
        } else { throw }
    }

    # ----------------------------------------------------------
    # Add a new version with the current value
    # ----------------------------------------------------------
    Write-Log "Adding new secret version..."

    $EncodedValue  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SecretValue))
    $VersionBody   = @{ payload = @{ data = $EncodedValue } } | ConvertTo-Json -Compress

    $VersionResponse = Invoke-RestMethod `
        -Uri        "$SmBase/$SecretResource`:addVersion" `
        -Method     POST `
        -Headers    $GcpHeaders `
        -Body       $VersionBody `
        -TimeoutSec 15

    $NewVersionName = $VersionResponse.name
    Write-Log "New version created: $NewVersionName"

    # ----------------------------------------------------------
    # Optionally disable all previous versions
    # ----------------------------------------------------------
    if ($env:GCP_DISABLE_PREVIOUS_VERSIONS -eq 'true') {
        Write-Log "Disabling previous enabled versions..."

        $VersionsList = Invoke-RestMethod `
            -Uri        "$SmBase/$SecretResource/versions?filter=state%3DENABLED" `
            -Headers    $GcpHeaders `
            -TimeoutSec 15

        foreach ($Ver in $VersionsList.versions) {
            if ($Ver.name -eq $NewVersionName) { continue }
            Write-Log "Disabling: $($Ver.name)..."
            Invoke-RestMethod `
                -Uri        "$SmBase/$($Ver.name)`:disable" `
                -Method     POST `
                -Headers    $GcpHeaders `
                -Body       '{}' `
                -TimeoutSec 15 | Out-Null
        }
    }

    Write-Log "Sync complete: secret written to GCP Secret Manager '$SecretResource'."
    exit 0
}
catch {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Error "[$ts] FAILED: $($_.Exception.Message)"
    exit 1
}
