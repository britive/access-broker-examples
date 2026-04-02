# ============================================================
# Britive Broker → Azure Key Vault Secret Synchronization
# ============================================================
# Writes a secret value to an Azure Key Vault secret.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script — no API
# calls back to Britive are needed.
#
# Authenticates to Azure AD via the service principal client
# credentials flow using Invoke-RestMethod.
#
# Compatible with both Windows PowerShell 5.1 and
# PowerShell Core 7+ (cross-platform).
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE          – The secret value to write
#   AZURE_TENANT_ID       – Azure AD (Entra ID) tenant ID
#   AZURE_CLIENT_ID       – Service principal / app registration ID
#   AZURE_CLIENT_SECRET   – Service principal client secret
#   AZURE_VAULT_URL       – Key Vault URL
#                           e.g. https://myvault.vault.azure.net
#   AZURE_SECRET_NAME     – Secret name inside the Key Vault
#
# Optional env vars:
#   AZURE_SECRET_CONTENT_TYPE – Content-type tag (e.g. text/plain)
#   AZURE_SECRET_EXPIRES      – Expiry date/time (ISO 8601 string)
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

    if (-not $env:SECRET_VALUE)       { throw "SECRET_VALUE is not set."       }
    if (-not $env:AZURE_TENANT_ID)    { throw "AZURE_TENANT_ID is not set."    }
    if (-not $env:AZURE_CLIENT_ID)    { throw "AZURE_CLIENT_ID is not set."    }
    if (-not $env:AZURE_CLIENT_SECRET){ throw "AZURE_CLIENT_SECRET is not set."}
    if (-not $env:AZURE_VAULT_URL)    { throw "AZURE_VAULT_URL is not set."    }
    if (-not $env:AZURE_SECRET_NAME)  { throw "AZURE_SECRET_NAME is not set."  }

    $SecretValue   = $env:SECRET_VALUE
    $AzureTenantId = $env:AZURE_TENANT_ID
    $AzureClientId = $env:AZURE_CLIENT_ID
    $AzureClientSec= $env:AZURE_CLIENT_SECRET
    $AzureVaultUrl = $env:AZURE_VAULT_URL.TrimEnd('/')
    $AzureSecretName = $env:AZURE_SECRET_NAME

    Write-Log "Target Key Vault : $AzureVaultUrl"
    Write-Log "Secret name      : $AzureSecretName"

    # ----------------------------------------------------------
    # Obtain Azure AD bearer token (client credentials flow)
    # ----------------------------------------------------------
    Write-Log "Acquiring Azure AD access token..."

    $TokenResponse = Invoke-RestMethod `
        -Uri         "https://login.microsoftonline.com/$AzureTenantId/oauth2/v2.0/token" `
        -Method      POST `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body        @{
            grant_type    = 'client_credentials'
            client_id     = $AzureClientId
            client_secret = $AzureClientSec
            scope         = 'https://vault.azure.net/.default'
        } `
        -TimeoutSec 15

    $AccessToken = $TokenResponse.access_token
    if ([string]::IsNullOrEmpty($AccessToken)) { throw "Azure AD returned an empty access token." }

    Write-Log "Azure AD token acquired (token not logged)."

    # ----------------------------------------------------------
    # Write secret to Azure Key Vault via REST API
    # ----------------------------------------------------------
    Write-Log "Writing secret to Azure Key Vault..."

    $KvPayload = @{ value = $SecretValue }

    if ($env:AZURE_SECRET_CONTENT_TYPE) { $KvPayload['contentType'] = $env:AZURE_SECRET_CONTENT_TYPE }
    if ($env:AZURE_SECRET_EXPIRES) {
        $KvPayload['attributes'] = @{
            exp = [DateTimeOffset]::Parse($env:AZURE_SECRET_EXPIRES).ToUnixTimeSeconds()
        }
    }

    Invoke-RestMethod `
        -Uri        "$AzureVaultUrl/secrets/$AzureSecretName`?api-version=7.4" `
        -Method     PUT `
        -Headers    @{ 'Authorization' = "Bearer $AccessToken"; 'Content-Type' = 'application/json' } `
        -Body       ($KvPayload | ConvertTo-Json -Compress) `
        -TimeoutSec 15 | Out-Null

    Write-Log "Sync complete: secret written to Azure Key Vault '$AzureSecretName'."
    exit 0
}
catch {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Error "[$ts] FAILED: $($_.Exception.Message)"
    exit 1
}
