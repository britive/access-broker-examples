#!/usr/bin/env bash
# ============================================================
# Lab Test — Azure Key Vault
# ============================================================
# Simulates what the Britive broker does:
#   1. Sources .env (credentials written by setup.sh)
#   2. Sets SECRET_VALUE to a unique timestamped string
#   3. Calls each sync script variant (bash CLI, curl, PS1)
#   4. Reads the secret back from Key Vault and verifies
#
# Run setup.sh first.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="${SCRIPT_DIR}/../../azure"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

# ── Load credentials ─────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || { err ".env not found — run setup.sh first."; exit 1; }
set -a; source "${ENV_FILE}"; set +a

# ── Unique test value ─────────────────────────────────────────
SECRET_VALUE="britive-lab-azure-$(date +%s)"
export SECRET_VALUE AZURE_VAULT_URL AZURE_SECRET_NAME \
       AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET

log "Test value : ${SECRET_VALUE}"
log "Vault URL  : ${AZURE_VAULT_URL}"
log "Secret name: ${AZURE_SECRET_NAME}"
log ""

# ── Helper: verify secret in Key Vault ──────────────────────
verify_azure() {
    local label="$1"
    local expected="$2"
    local actual
    # Use the SP credentials to read back the value
    actual=$(az keyvault secret show \
        --vault-name "${VAULT_NAME}" \
        --name       "${AZURE_SECRET_NAME}" \
        --query      'value' \
        --output     tsv 2>/dev/null || echo "__READ_FAILED__")
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${label}"
    else
        fail "${label}"
        err "  Expected : ${expected}"
        err "  Got      : ${actual}"
    fi
}

# ── Log in the Azure CLI as the service principal ────────────
# The CLI variant uses 'az keyvault secret set' which needs an az session.
log "Authenticating Azure CLI as service principal..."
az login \
    --service-principal \
    --username "${AZURE_CLIENT_ID}" \
    --password "${AZURE_CLIENT_SECRET}" \
    --tenant   "${AZURE_TENANT_ID}" \
    --output none

# ── Bash CLI variant ──────────────────────────────────────────
log "=== Variant 1: bash CLI (sync-to-azure-key-vault.sh) ==="
bash "${SYNC_DIR}/sync-to-azure-key-vault.sh"
verify_azure "bash CLI variant" "${SECRET_VALUE}"
log ""

# ── Update value for next variant ────────────────────────────
SECRET_VALUE="britive-lab-azure-curl-$(date +%s)"
export SECRET_VALUE

# ── Bash curl variant ─────────────────────────────────────────
log "=== Variant 2: bash curl (sync-to-azure-key-vault-curl.sh) ==="
bash "${SYNC_DIR}/sync-to-azure-key-vault-curl.sh"
verify_azure "bash curl variant" "${SECRET_VALUE}"
log ""

# ── PowerShell variant (optional) ────────────────────────────
if command -v pwsh &>/dev/null; then
    SECRET_VALUE="britive-lab-azure-ps1-$(date +%s)"
    export SECRET_VALUE
    log "=== Variant 3: PowerShell (sync-to-azure-key-vault.ps1) ==="
    pwsh -NonInteractive -File "${SYNC_DIR}/sync-to-azure-key-vault.ps1"
    verify_azure "PowerShell variant" "${SECRET_VALUE}"
    log ""
else
    log "=== Variant 3: PowerShell — skipped (pwsh not found) ==="
    log ""
fi

# ── Summary ───────────────────────────────────────────────────
echo "──────────────────────────────────────────"
if [[ ${FAILURES} -eq 0 ]]; then
    echo "All tests passed."
else
    echo "${FAILURES} test(s) FAILED."
    exit 1
fi
