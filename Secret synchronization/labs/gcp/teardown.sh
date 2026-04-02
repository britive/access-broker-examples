#!/usr/bin/env bash
# ============================================================
# Lab Teardown — GCP Secret Manager
# ============================================================
# Deletes every resource created by setup.sh:
#   - All secret versions (required before secret deletion)
#   - The Secret Manager secret
#   - The service account key
#   - The service account
#   - Local sa-key.json and .env files
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
SA_KEY_FILE="${SCRIPT_DIR}/sa-key.json"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN: $*" >&2; }

# ── Load resource names ───────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || { warn ".env not found — nothing to clean up."; exit 0; }
# shellcheck disable=SC1090
source "${ENV_FILE}"

PROJECT="${GCP_PROJECT_ID:-}"
SECRET="${GCP_SECRET_NAME:-britive-lab-test-secret}"
SA_EMAIL="${LAB_SA_EMAIL:-}"

[[ -z "${PROJECT}" ]] && { warn "GCP_PROJECT_ID not set in .env"; exit 1; }

# ── Switch back to default credentials for deletion ──────────
gcloud config unset auth/impersonate_service_account 2>/dev/null || true
gcloud auth application-default login --quiet 2>/dev/null || true

# ── Delete all secret versions ────────────────────────────────
log "Listing secret versions for '${SECRET}'..."
VERSIONS=$(gcloud secrets versions list "${SECRET}" \
    --project="${PROJECT}" \
    --filter="state=ENABLED OR state=DISABLED" \
    --format="value(name)" 2>/dev/null || echo "")

for VERSION in ${VERSIONS}; do
    VERSION_ID=$(basename "${VERSION}")
    log "  Destroying version ${VERSION_ID}..."
    gcloud secrets versions destroy "${VERSION_ID}" \
        --secret="${SECRET}" \
        --project="${PROJECT}" \
        --quiet 2>/dev/null || warn "  Could not destroy version ${VERSION_ID}"
done

# ── Delete secret ─────────────────────────────────────────────
log "Deleting secret '${SECRET}'..."
gcloud secrets delete "${SECRET}" \
    --project="${PROJECT}" \
    --quiet 2>/dev/null \
    && log "  Secret deleted." \
    || warn "  Secret not found or already deleted."

# ── Delete SA key ─────────────────────────────────────────────
if [[ -n "${SA_EMAIL}" ]] && [[ -f "${SA_KEY_FILE}" ]]; then
    KEY_ID=$(jq -r '.private_key_id' "${SA_KEY_FILE}" 2>/dev/null || echo "")
    if [[ -n "${KEY_ID}" ]]; then
        log "Deleting SA key ${KEY_ID}..."
        gcloud iam service-accounts keys delete "${KEY_ID}" \
            --iam-account="${SA_EMAIL}" \
            --project="${PROJECT}" \
            --quiet 2>/dev/null \
            && log "  Key deleted." \
            || warn "  Key not found or already deleted."
    fi
fi

# ── Delete service account ────────────────────────────────────
if [[ -n "${SA_EMAIL}" ]]; then
    log "Deleting service account '${SA_EMAIL}'..."
    gcloud iam service-accounts delete "${SA_EMAIL}" \
        --project="${PROJECT}" \
        --quiet 2>/dev/null \
        && log "  Service account deleted." \
        || warn "  SA not found or already deleted."
fi

# ── Remove local files ────────────────────────────────────────
rm -f "${SA_KEY_FILE}" && log "sa-key.json removed."
rm -f "${ENV_FILE}"    && log ".env removed."

log "Teardown complete."
