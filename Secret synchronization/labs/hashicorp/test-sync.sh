#!/usr/bin/env bash
# ============================================================
# Lab Test — HashiCorp Vault
# ============================================================
# Simulates what the Britive broker does:
#   1. Sources .env (credentials written by setup.sh)
#   2. Sets SECRET_VALUE to a unique timestamped string
#   3. Calls each sync script variant:
#      - bash CLI (token auth)
#      - bash curl (token auth)
#      - bash curl (AppRole auth)
#      - PowerShell (if pwsh present)
#   4. Reads the secret back from Vault and verifies
#
# Run setup.sh first (starts the Docker Vault container).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="${SCRIPT_DIR}/../../hashicorp"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

# ── Load credentials ─────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || { err ".env not found — run setup.sh first."; exit 1; }
set -a; source "${ENV_FILE}"; set +a

# ── Verify Vault is reachable ─────────────────────────────────
export VAULT_ADDR VAULT_TOKEN VAULT_SECRET_PATH VAULT_SECRET_KEY VAULT_KV_VERSION

vault status -address="${VAULT_ADDR}" &>/dev/null \
    || { err "Vault not reachable at ${VAULT_ADDR}. Is the Docker container running?"; exit 1; }

# ── Helper: verify secret in Vault ──────────────────────────
verify_vault() {
    local label="$1"
    local expected="$2"
    local actual
    actual=$(VAULT_TOKEN="${LAB_ROOT_TOKEN}" \
        vault kv get \
            -address="${VAULT_ADDR}" \
            -field="${VAULT_SECRET_KEY}" \
            "${VAULT_SECRET_PATH}" 2>/dev/null || echo "__READ_FAILED__")
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${label}"
    else
        fail "${label}"
        err "  Expected : ${expected}"
        err "  Got      : ${actual}"
    fi
}

log "Vault     : ${VAULT_ADDR}"
log "Secret    : ${VAULT_SECRET_PATH}  key: ${VAULT_SECRET_KEY}"
log ""

# ── Bash CLI variant (token auth) ────────────────────────────
SECRET_VALUE="britive-lab-hcv-$(date +%s)"
export SECRET_VALUE

log "=== Variant 1: bash CLI — token auth (sync-to-hashicorp-vault.sh) ==="
bash "${SYNC_DIR}/sync-to-hashicorp-vault.sh"
verify_vault "bash CLI (token auth)" "${SECRET_VALUE}"
log ""

# ── Bash curl variant — token auth ───────────────────────────
SECRET_VALUE="britive-lab-hcv-curl-$(date +%s)"
export SECRET_VALUE
# Unset AppRole vars so the curl script uses token auth
unset VAULT_ROLE_ID VAULT_SECRET_ID_AR 2>/dev/null || true

log "=== Variant 2: bash curl — token auth (sync-to-hashicorp-vault-curl.sh) ==="
bash "${SYNC_DIR}/sync-to-hashicorp-vault-curl.sh"
verify_vault "bash curl (token auth)" "${SECRET_VALUE}"
log ""

# ── Bash curl variant — AppRole auth ─────────────────────────
SECRET_VALUE="britive-lab-hcv-approle-$(date +%s)"
export SECRET_VALUE VAULT_ROLE_ID VAULT_SECRET_ID_AR

log "=== Variant 3: bash curl — AppRole auth (sync-to-hashicorp-vault-curl.sh) ==="
# Unset token so the curl script falls through to AppRole
SAVED_TOKEN="${VAULT_TOKEN}"
unset VAULT_TOKEN
bash "${SYNC_DIR}/sync-to-hashicorp-vault-curl.sh"
export VAULT_TOKEN="${SAVED_TOKEN}"
verify_vault "bash curl (AppRole auth)" "${SECRET_VALUE}"
log ""

# ── PowerShell variant (optional) ────────────────────────────
if command -v pwsh &>/dev/null; then
    SECRET_VALUE="britive-lab-hcv-ps1-$(date +%s)"
    export SECRET_VALUE VAULT_TOKEN
    log "=== Variant 4: PowerShell (sync-to-hashicorp-vault.ps1) ==="
    pwsh -NonInteractive -File "${SYNC_DIR}/sync-to-hashicorp-vault.ps1"
    verify_vault "PowerShell variant" "${SECRET_VALUE}"
    log ""
else
    log "=== Variant 4: PowerShell — skipped (pwsh not found) ==="
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
