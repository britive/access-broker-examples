#!/usr/bin/env bash
# ============================================================
# Britive Broker → GCP Secret Manager Secret Synchronization
# (curl / REST API variant)
# ============================================================
# Adds a new version to a GCP Secret Manager secret using the
# GCP REST API — no gcloud CLI required.
# Authenticates using a service account key file, a pre-obtained
# access token, or the GCE/GKE instance metadata server.
#
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Prerequisites:
#   - curl, jq, base64  installed
#   - For SA key auth: also openssl
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

SM_BASE="https://secretmanager.googleapis.com/v1"
SECRET_RESOURCE="projects/${GCP_PROJECT_ID}/secrets/${GCP_SECRET_NAME}"

log "GCP project    : ${GCP_PROJECT_ID}"
log "GCP secret     : ${GCP_SECRET_NAME}"

# ----------------------------------------------------------
# Obtain GCP access token
# ----------------------------------------------------------
obtain_token_from_sa_key() {
    local key_file="$1"
    local client_email private_key now exp header claims signing_input signature jwt

    client_email=$(jq -r '.client_email' "${key_file}")
    private_key=$(jq -r '.private_key'   "${key_file}")

    header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64 -w 0 | tr '+/' '-_' | tr -d '=')

    now=$(date +%s)
    exp=$((now + 3600))

    claims=$(jq -n \
        --arg iss "${client_email}" \
        --arg scope "https://www.googleapis.com/auth/cloud-platform" \
        --argjson iat "${now}" \
        --argjson exp "${exp}" \
        '{"iss":$iss,"scope":$scope,"aud":"https://oauth2.googleapis.com/token","iat":$iat,"exp":$exp}' \
        | base64 -w 0 | tr '+/' '-_' | tr -d '=')

    signing_input="${header}.${claims}"

    signature=$(printf '%s' "${signing_input}" \
        | openssl dgst -sha256 -sign <(printf '%s' "${private_key}") \
        | base64 -w 0 | tr '+/' '-_' | tr -d '=')

    jwt="${signing_input}.${signature}"

    curl -sf --max-time 15 \
        -X POST "https://oauth2.googleapis.com/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "assertion=${jwt}" \
        | jq -r '.access_token'
}

if [[ -n "${GCP_ACCESS_TOKEN:-}" ]]; then
    ACCESS_TOKEN="${GCP_ACCESS_TOKEN}"
    log "Using provided GCP_ACCESS_TOKEN."
elif [[ -n "${GCP_SA_KEY_FILE:-}" ]]; then
    [[ -f "${GCP_SA_KEY_FILE}" ]] || die "GCP_SA_KEY_FILE not found: ${GCP_SA_KEY_FILE}"
    log "Generating access token from service account key..."
    ACCESS_TOKEN=$(obtain_token_from_sa_key "${GCP_SA_KEY_FILE}")
    log "Access token obtained (not logged)."
else
    log "Fetching access token from instance metadata server..."
    ACCESS_TOKEN=$(curl -sf --max-time 5 \
        -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        | jq -r '.access_token') \
        || die "Metadata server unavailable. Set GCP_ACCESS_TOKEN or GCP_SA_KEY_FILE."
    log "Access token obtained from metadata server."
fi

[[ -z "${ACCESS_TOKEN}" ]] && die "GCP access token is empty."

# ----------------------------------------------------------
# Ensure the GCP secret resource exists; create if not
# ----------------------------------------------------------
log "Checking if secret '${GCP_SECRET_NAME}' exists..."

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${SM_BASE}/${SECRET_RESOURCE}")

if [[ "${HTTP_STATUS}" == "404" ]]; then
    log "Secret not found — creating it..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        "${SM_BASE}/projects/${GCP_PROJECT_ID}/secrets?secretId=${GCP_SECRET_NAME}" \
        -d '{"replication": {"automatic": {}}}')
    [[ "${HTTP_STATUS}" == "200" ]] \
        || die "Failed to create GCP secret (HTTP ${HTTP_STATUS})."
    log "Secret created."
elif [[ "${HTTP_STATUS}" != "200" ]]; then
    die "Unexpected HTTP status when checking secret: ${HTTP_STATUS}."
fi

# ----------------------------------------------------------
# Add a new version with the current value.
# SECRET_VALUE is piped into base64 rather than passed as
# an argument to keep it out of the process list.
# ----------------------------------------------------------
log "Adding new secret version..."

ENCODED_VALUE=$(printf '%s' "${SECRET_VALUE}" | base64 -w 0)

# Build payload with jq -Rs to avoid secret in --arg
VERSION_PAYLOAD=$(printf '%s' "${ENCODED_VALUE}" | jq -Rs '{"payload": {"data": .}}')

VERSION_RESPONSE=$(curl -sf \
    --max-time 15 \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "${SM_BASE}/${SECRET_RESOURCE}:addVersion" \
    -d "${VERSION_PAYLOAD}") \
    || die "Failed to add secret version."

NEW_VERSION=$(echo "${VERSION_RESPONSE}" | jq -r '.name')
log "New version created: ${NEW_VERSION}"

# ----------------------------------------------------------
# Optionally disable all previous versions
# ----------------------------------------------------------
if [[ "${GCP_DISABLE_PREVIOUS_VERSIONS:-false}" == "true" ]]; then
    log "Disabling previous enabled versions..."

    VERSIONS=$(curl -sf \
        --max-time 15 \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${SM_BASE}/${SECRET_RESOURCE}/versions?filter=state%3DENABLED" \
        | jq -r '.versions[]?.name // empty')

    while IFS= read -r VERSION; do
        [[ "${VERSION}" == "${NEW_VERSION}" ]] && continue
        curl -sf \
            --max-time 15 \
            -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            "${SM_BASE}/${VERSION}:disable" \
            -d '{}' > /dev/null \
            && log "Disabled: ${VERSION}"
    done <<< "${VERSIONS}"
fi

log "Sync complete: secret written to GCP Secret Manager '${SECRET_RESOURCE}'."
