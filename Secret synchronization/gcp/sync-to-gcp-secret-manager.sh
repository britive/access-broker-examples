#!/usr/bin/env bash
# ============================================================
# Britive Broker → GCP Secret Manager Secret Synchronization
# ============================================================
# Adds a new version to a GCP Secret Manager secret.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script — no API
# calls back to Britive are needed.
#
# A new secret version is added on each run. Set
# GCP_DISABLE_PREVIOUS_VERSIONS=true to automatically disable
# older enabled versions after a successful sync.
#
# Prerequisites:
#   - gcloud CLI installed, authenticated, and on PATH
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE        – The secret value to write
#   GCP_PROJECT_ID      – GCP project ID where the secret lives
#   GCP_SECRET_NAME     – Secret name in Secret Manager
#
# Optional env vars:
#   GCP_DISABLE_PREVIOUS_VERSIONS – Set to "true" to disable all
#                                   previous versions after sync
#   GCP_SA_KEY_FILE     – Path to a service account JSON key file;
#                         activates that SA before running gcloud
# ============================================================

set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ----------------------------------------------------------
# Validate required environment variables
# ----------------------------------------------------------
log "Validating environment variables..."

[[ -z "${SECRET_VALUE:-}" ]]    && die "SECRET_VALUE is not set."
[[ -z "${GCP_PROJECT_ID:-}" ]]  && die "GCP_PROJECT_ID is not set."
[[ -z "${GCP_SECRET_NAME:-}" ]] && die "GCP_SECRET_NAME is not set."

log "GCP project    : ${GCP_PROJECT_ID}"
log "GCP secret     : ${GCP_SECRET_NAME}"

# ----------------------------------------------------------
# Activate service account if key file provided
# ----------------------------------------------------------
if [[ -n "${GCP_SA_KEY_FILE:-}" ]]; then
    [[ -f "${GCP_SA_KEY_FILE}" ]] || die "GCP_SA_KEY_FILE not found: ${GCP_SA_KEY_FILE}"
    log "Activating service account from key file..."
    gcloud auth activate-service-account \
        --key-file="${GCP_SA_KEY_FILE}" \
        --quiet \
        || die "gcloud auth activate-service-account failed."
fi

# ----------------------------------------------------------
# Ensure the GCP secret resource exists; create if not
# ----------------------------------------------------------
if ! gcloud secrets describe "${GCP_SECRET_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        --quiet > /dev/null 2>&1; then
    log "Secret '${GCP_SECRET_NAME}' not found — creating it..."
    gcloud secrets create "${GCP_SECRET_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        --replication-policy="automatic" \
        --quiet \
        || die "Failed to create GCP secret '${GCP_SECRET_NAME}'."
    log "Secret created."
fi

# ----------------------------------------------------------
# Add a new version with the current value
# ----------------------------------------------------------
log "Adding new secret version to GCP Secret Manager..."

echo -n "${SECRET_VALUE}" \
    | gcloud secrets versions add "${GCP_SECRET_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        --data-file=- \
        --quiet \
        || die "gcloud secrets versions add failed."

log "New version added successfully."

# ----------------------------------------------------------
# Optionally disable all previous versions
# ----------------------------------------------------------
if [[ "${GCP_DISABLE_PREVIOUS_VERSIONS:-false}" == "true" ]]; then
    log "Disabling previous secret versions..."

    VERSIONS=$(gcloud secrets versions list "${GCP_SECRET_NAME}" \
        --project="${GCP_PROJECT_ID}" \
        --filter="state=ENABLED" \
        --format="value(name)" \
        --sort-by="~createTime" \
        | tail -n +2)   # skip the latest (first in reverse-sorted list)

    if [[ -n "${VERSIONS}" ]]; then
        while IFS= read -r VERSION; do
            VERSION_ID=$(basename "${VERSION}")
            gcloud secrets versions disable "${VERSION_ID}" \
                --secret="${GCP_SECRET_NAME}" \
                --project="${GCP_PROJECT_ID}" \
                --quiet \
                && log "Disabled version: ${VERSION_ID}"
        done <<< "${VERSIONS}"
    else
        log "No previous versions to disable."
    fi
fi

log "Sync complete: secret written to GCP Secret Manager 'projects/${GCP_PROJECT_ID}/secrets/${GCP_SECRET_NAME}'."
