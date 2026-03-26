#!/usr/bin/env bash
# ============================================================
# Lab Test — AWS Secrets Manager
# ============================================================
# Simulates what the Britive broker does:
#   1. Sources .env (credentials written by setup.sh)
#   2. Sets SECRET_VALUE to a unique timestamped string
#   3. Calls each sync script variant (bash CLI, curl, PS1)
#   4. Reads the secret back from AWS and verifies the value
#
# Run setup.sh first.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="${SCRIPT_DIR}/../../aws"
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
SECRET_VALUE="britive-lab-aws-$(date +%s)"
export SECRET_VALUE AWS_SECRET_NAME AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

log "Test value: ${SECRET_VALUE}"
log "Target    : ${AWS_SECRET_NAME} (${AWS_REGION})"
log ""

# ── Helper: verify secret in AWS ────────────────────────────
verify_aws() {
    local label="$1"
    local expected="$2"
    local actual
    actual=$(aws secretsmanager get-secret-value \
        --secret-id "${AWS_SECRET_NAME}" \
        --region    "${AWS_REGION}" \
        --query     'SecretString' \
        --output    text 2>/dev/null || echo "__READ_FAILED__")
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${label}"
    else
        fail "${label}"
        err "  Expected : ${expected}"
        err "  Got      : ${actual}"
    fi
}

# ── Bash CLI variant ──────────────────────────────────────────
log "=== Variant 1: bash CLI (sync-to-aws-secrets-manager.sh) ==="
bash "${SYNC_DIR}/sync-to-aws-secrets-manager.sh"
verify_aws "bash CLI variant" "${SECRET_VALUE}"
log ""

# ── Update value for next variant so each test is distinct ───
SECRET_VALUE="britive-lab-aws-curl-$(date +%s)"
export SECRET_VALUE

# ── Bash curl variant ─────────────────────────────────────────
log "=== Variant 2: bash curl (sync-to-aws-secrets-manager-curl.sh) ==="
bash "${SYNC_DIR}/sync-to-aws-secrets-manager-curl.sh"
verify_aws "bash curl variant" "${SECRET_VALUE}"
log ""

# ── PowerShell variant (optional) ────────────────────────────
if command -v pwsh &>/dev/null; then
    SECRET_VALUE="britive-lab-aws-ps1-$(date +%s)"
    export SECRET_VALUE
    log "=== Variant 3: PowerShell (sync-to-aws-secrets-manager.ps1) ==="
    pwsh -NonInteractive -File "${SYNC_DIR}/sync-to-aws-secrets-manager.ps1"
    verify_aws "PowerShell variant" "${SECRET_VALUE}"
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
