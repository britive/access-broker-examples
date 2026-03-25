# ============================================================
# Britive Broker → HashiCorp Vault Secret Synchronization
# ============================================================
# Writes a secret value to a HashiCorp Vault KV secret.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script — no API
# calls back to Britive are needed.
#
# Uses the Vault HTTP API via Invoke-RestMethod.
# Supports token auth, AppRole auth, and both KV v1 and KV v2.
#
# Compatible with both Windows PowerShell 5.1 and
# PowerShell Core 7+ (cross-platform).
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE        – The secret value to write
#   VAULT_ADDR          – HashiCorp Vault server address
#   VAULT_TOKEN         – Vault token with write access
#                         (or use AppRole vars below instead)
#   VAULT_SECRET_PATH   – KV path, e.g. secret/my-app/database
#   VAULT_SECRET_KEY    – Key name within the KV secret
#
# AppRole auth (alternative to VAULT_TOKEN):
#   VAULT_ROLE_ID       – AppRole role ID
#   VAULT_SECRET_ID_AR  – AppRole secret ID
#
# Optional env vars:
#   VAULT_NAMESPACE     – Vault namespace (HCP Vault / Enterprise)
#   VAULT_KV_VERSION    – KV engine version: "1" or "2" (default: 2)
#   VAULT_MOUNT_PATH    – KV mount path (default: secret)
#   VAULT_SKIP_VERIFY   – Set to "true" to skip TLS verification
# ============================================================

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$ts] $Message"
}

if ($env:VAULT_SKIP_VERIFY -eq 'true') {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
    } else {
        Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int err) { return true; }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
    }
}

try {
    # ----------------------------------------------------------
    # Validate required environment variables
    # ----------------------------------------------------------
    Write-Log "Validating environment variables..."

    if (-not $env:SECRET_VALUE)       { throw "SECRET_VALUE is not set."       }
    if (-not $env:VAULT_ADDR)         { throw "VAULT_ADDR is not set."         }
    if (-not $env:VAULT_SECRET_PATH)  { throw "VAULT_SECRET_PATH is not set."  }
    if (-not $env:VAULT_SECRET_KEY)   { throw "VAULT_SECRET_KEY is not set."   }

    $SecretValue    = $env:SECRET_VALUE
    $VaultAddr      = $env:VAULT_ADDR.TrimEnd('/')
    $VaultSecretPath= $env:VAULT_SECRET_PATH
    $VaultSecretKey = $env:VAULT_SECRET_KEY
    $VaultKvVersion = if ($env:VAULT_KV_VERSION) { $env:VAULT_KV_VERSION } else { '2' }
    $VaultMountPath = if ($env:VAULT_MOUNT_PATH)  { $env:VAULT_MOUNT_PATH  } else { 'secret' }
    $VaultNamespace = $env:VAULT_NAMESPACE

    Write-Log "Vault address   : $VaultAddr"
    Write-Log "Vault KV path   : $VaultSecretPath"
    Write-Log "Vault KV key    : $VaultSecretKey"
    Write-Log "KV version      : $VaultKvVersion"

    # ----------------------------------------------------------
    # Authenticate to HashiCorp Vault
    # ----------------------------------------------------------
    $HcvHeaders = @{ 'Content-Type' = 'application/json' }
    if ($VaultNamespace) { $HcvHeaders['X-Vault-Namespace'] = $VaultNamespace }

    if ($env:VAULT_TOKEN) {
        $HcvHeaders['X-Vault-Token'] = $env:VAULT_TOKEN
        Write-Log "Using provided VAULT_TOKEN."
    } elseif ($env:VAULT_ROLE_ID -and $env:VAULT_SECRET_ID_AR) {
        Write-Log "Authenticating via AppRole..."

        $AuthBody = @{ role_id = $env:VAULT_ROLE_ID; secret_id = $env:VAULT_SECRET_ID_AR } | ConvertTo-Json -Compress
        $AuthResponse = Invoke-RestMethod `
            -Uri        "$VaultAddr/v1/auth/approle/login" `
            -Method     POST `
            -Headers    $HcvHeaders `
            -Body       $AuthBody `
            -TimeoutSec 15

        $HcvToken = $AuthResponse.auth.client_token
        if ([string]::IsNullOrEmpty($HcvToken)) { throw "AppRole login returned an empty token." }
        $HcvHeaders['X-Vault-Token'] = $HcvToken
        Write-Log "AppRole authentication successful (token not logged)."
    } else {
        throw "No Vault credentials found. Set VAULT_TOKEN or VAULT_ROLE_ID + VAULT_SECRET_ID_AR."
    }

    # ----------------------------------------------------------
    # Write secret to HashiCorp Vault
    # ----------------------------------------------------------
    Write-Log "Writing secret to HashiCorp Vault (KV v$VaultKvVersion)..."

    if ($VaultKvVersion -eq '2') {
        if ($VaultSecretPath -notlike "*`/data`/*") {
            $RelPath = $VaultSecretPath -replace "^$VaultMountPath/", ''
            $ApiPath = "$VaultMountPath/data/$RelPath"
        } else {
            $ApiPath = $VaultSecretPath
        }
        $Payload = @{ data = @{ $VaultSecretKey = $SecretValue } } | ConvertTo-Json -Compress
    } else {
        $ApiPath = $VaultSecretPath
        $Payload = @{ $VaultSecretKey = $SecretValue } | ConvertTo-Json -Compress
    }

    Invoke-RestMethod `
        -Uri        "$VaultAddr/v1/$ApiPath" `
        -Method     POST `
        -Headers    $HcvHeaders `
        -Body       $Payload `
        -TimeoutSec 15 | Out-Null

    Write-Log "Sync complete: secret written to Vault '$VaultAddr/$ApiPath' key '$VaultSecretKey'."
    exit 0
}
catch {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Error "[$ts] FAILED: $($_.Exception.Message)"
    exit 1
}
