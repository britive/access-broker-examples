#!/usr/bin/env bash
# ============================================================
# Lab Test — GCP Secret Manager
# ============================================================
# Simulates what the Britive broker does:
#   1. Sources .env (credentials written by setup.sh)
#   2. Sets SECRET_VALUE to a unique timestamped string
#   3. Calls each sync script variant (bash CLI, curl, PS1)
#   4. Reads the latest secret version back and verifies
#
# Run setup.sh first.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="${SCRIPT_DIR}/../../gcp"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

# ── Load credentials ─────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || { err ".env not found — run setup.sh first."; exit 1; }
set -a; source "${ENV_FILE}"; set +a

export GCP_PROJECT_ID GCP_SECRET_NAME GCP_SA_KEY_FILE

log "Project : ${GCP_PROJECT_ID}"
log "Secret  : ${GCP_SECRET_NAME}"
log ""

# ── Helper: verify latest version in Secret Manager ─────────
verify_gcp() {
    local label="$1"
    local expected="$2"
    local actual
    # Activate the SA so gcloud has access for verification
    actual=$(gcloud secrets versions access latest \
        --secret="${GCP_SECRET_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        2>/dev/null || echo "__READ_FAILED__")
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${label}"
    else
        fail "${label}"
        err "  Expected : ${expected}"
        err "  Got      : ${actual}"
    fi
}

# ── Activate SA for gcloud (used for verification calls) ────
log "Activating service account for gcloud verification calls..."
gcloud auth activate-service-account \
    --key-file="${GCP_SA_KEY_FILE}" \
    --quiet 2>/dev/null

# ── Bash CLI variant ──────────────────────────────────────────
SECRET_VALUE="britive-lab-gcp-$(date +%s)"
export SECRET_VALUE

log "=== Variant 1: bash CLI (sync-to-gcp-secret-manager.sh) ==="
bash "${SYNC_DIR}/sync-to-gcp-secret-manager.sh"
verify_gcp "bash CLI variant" "${SECRET_VALUE}"
log ""

# ── Bash curl variant ─────────────────────────────────────────
SECRET_VALUE="britive-lab-gcp-curl-$(date +%s)"
export SECRET_VALUE

log "=== Variant 2: bash curl (sync-to-gcp-secret-manager-curl.sh) ==="
bash "${SYNC_DIR}/sync-to-gcp-secret-manager-curl.sh"
verify_gcp "bash curl variant" "${SECRET_VALUE}"
log ""

# ── PowerShell variant (optional) ────────────────────────────
if command -v pwsh &>/dev/null; then
    SECRET_VALUE="britive-lab-gcp-ps1-$(date +%s)"
    export SECRET_VALUE
    log "=== Variant 3: PowerShell (sync-to-gcp-secret-manager.ps1) ==="
    pwsh -NonInteractive -File "${SYNC_DIR}/sync-to-gcp-secret-manager.ps1"
    verify_gcp "PowerShell variant" "${SECRET_VALUE}"
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
