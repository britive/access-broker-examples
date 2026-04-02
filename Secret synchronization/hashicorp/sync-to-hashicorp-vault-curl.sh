#!/usr/bin/env bash
# ============================================================
# Britive Broker → HashiCorp Vault Secret Synchronization
# (curl / REST API variant)
# ============================================================
# Writes a secret value to a HashiCorp Vault KV secret using
# the Vault HTTP API — no Vault CLI required.
# Supports token auth, AppRole auth, and both KV v1 and KV v2.
#
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Prerequisites:
#   - curl, jq  installed
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

set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ----------------------------------------------------------
# Validate required environment variables
# ----------------------------------------------------------
log "Validating environment variables..."

[[ -z "${SECRET_VALUE:-}" ]]      && die "SECRET_VALUE is not set."
[[ -z "${VAULT_ADDR:-}" ]]        && die "VAULT_ADDR is not set."
[[ -z "${VAULT_SECRET_PATH:-}" ]] && die "VAULT_SECRET_PATH is not set."
[[ -z "${VAULT_SECRET_KEY:-}" ]]  && die "VAULT_SECRET_KEY is not set."

VAULT_KV_VERSION="${VAULT_KV_VERSION:-2}"
VAULT_MOUNT_PATH="${VAULT_MOUNT_PATH:-secret}"
VAULT_ADDR="${VAULT_ADDR%/}"

CURL_TLS_FLAG=""
[[ "${VAULT_SKIP_VERIFY:-false}" == "true" ]] && CURL_TLS_FLAG="-k"

NAMESPACE_HEADER=()
[[ -n "${VAULT_NAMESPACE:-}" ]] && NAMESPACE_HEADER=("-H" "X-Vault-Namespace: ${VAULT_NAMESPACE}")

log "Vault address   : ${VAULT_ADDR}"
log "Vault KV path   : ${VAULT_SECRET_PATH}"
log "Vault KV key    : ${VAULT_SECRET_KEY}"
log "KV version      : ${VAULT_KV_VERSION}"

# ----------------------------------------------------------
# Authenticate to HashiCorp Vault
# ----------------------------------------------------------
if [[ -n "${VAULT_TOKEN:-}" ]]; then
    HCV_TOKEN="${VAULT_TOKEN}"
    log "Using provided VAULT_TOKEN."
elif [[ -n "${VAULT_ROLE_ID:-}" && -n "${VAULT_SECRET_ID_AR:-}" ]]; then
    log "Authenticating via AppRole..."

    # Build AppRole body reading VAULT_SECRET_ID_AR from stdin via jq -Rs
    # to avoid the secret ID appearing as a jq process argument.
    APPROLE_BODY=$(printf '%s' "${VAULT_SECRET_ID_AR}" | jq -Rs \
        --arg rid "${VAULT_ROLE_ID}" \
        '{"role_id": $rid, "secret_id": .}')

    AUTH_RESPONSE=$(curl -sf ${CURL_TLS_FLAG} \
        --max-time 15 \
        -X POST \
        -H "Content-Type: application/json" \
        "${NAMESPACE_HEADER[@]}" \
        -d "${APPROLE_BODY}" \
        "${VAULT_ADDR}/v1/auth/approle/login") \
        || die "AppRole login request failed."

    HCV_TOKEN=$(echo "${AUTH_RESPONSE}" | jq -r '.auth.client_token // empty')
    [[ -z "${HCV_TOKEN}" ]] && die "AppRole login returned an empty token."
    log "AppRole authentication successful (token not logged)."
else
    die "No Vault credentials found. Set VAULT_TOKEN or VAULT_ROLE_ID + VAULT_SECRET_ID_AR."
fi

# ----------------------------------------------------------
# Build the KV payload.
# SECRET_VALUE is read from stdin via `jq -Rs` so it does
# not appear as a jq process argument visible in `ps aux`.
# ----------------------------------------------------------
if [[ "${VAULT_KV_VERSION}" == "2" ]]; then
    if [[ "${VAULT_SECRET_PATH}" != *"/data/"* ]]; then
        RELATIVE_PATH="${VAULT_SECRET_PATH#${VAULT_MOUNT_PATH}/}"
        API_PATH="${VAULT_MOUNT_PATH}/data/${RELATIVE_PATH}"
    else
        API_PATH="${VAULT_SECRET_PATH}"
    fi
    PAYLOAD=$(printf '%s' "${SECRET_VALUE}" | jq -Rs \
        --arg key "${VAULT_SECRET_KEY}" \
        '{"data": {($key): .}}')
else
    API_PATH="${VAULT_SECRET_PATH}"
    PAYLOAD=$(printf '%s' "${SECRET_VALUE}" | jq -Rs \
        --arg key "${VAULT_SECRET_KEY}" \
        '{($key): .}')
fi

# ----------------------------------------------------------
# Write secret to HashiCorp Vault via HTTP API
# ----------------------------------------------------------
log "Writing secret to HashiCorp Vault (KV v${VAULT_KV_VERSION})..."

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    ${CURL_TLS_FLAG} \
    --max-time 15 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Vault-Token: ${HCV_TOKEN}" \
    "${NAMESPACE_HEADER[@]}" \
    -d "${PAYLOAD}" \
    "${VAULT_ADDR}/v1/${API_PATH}")

case "${HTTP_STATUS}" in
    200|204) log "Secret written successfully (HTTP ${HTTP_STATUS})." ;;
    *)       die "Vault API returned unexpected HTTP status: ${HTTP_STATUS}." ;;
esac

log "Sync complete: secret written to Vault '${VAULT_ADDR}/${API_PATH}' key '${VAULT_SECRET_KEY}'."
