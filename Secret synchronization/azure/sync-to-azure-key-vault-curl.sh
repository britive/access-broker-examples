#!/usr/bin/env bash
# ============================================================
# Britive Broker → Azure Key Vault Secret Synchronization
# (curl / REST API variant)
# ============================================================
# Writes a secret value to an Azure Key Vault secret using
# the Azure REST API — no Azure CLI required.
# Authenticates to Azure AD as a service principal (client
# credentials flow) to obtain a bearer token, then calls the
# Key Vault REST API.
#
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Prerequisites:
#   - curl, jq  installed
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
#   AZURE_SECRET_EXPIRES      – Expiry (Unix timestamp as integer string)
# ============================================================

set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ----------------------------------------------------------
# Validate required environment variables
# ----------------------------------------------------------
log "Validating environment variables..."

[[ -z "${SECRET_VALUE:-}" ]]         && die "SECRET_VALUE is not set."
[[ -z "${AZURE_TENANT_ID:-}" ]]      && die "AZURE_TENANT_ID is not set."
[[ -z "${AZURE_CLIENT_ID:-}" ]]      && die "AZURE_CLIENT_ID is not set."
[[ -z "${AZURE_CLIENT_SECRET:-}" ]]  && die "AZURE_CLIENT_SECRET is not set."
[[ -z "${AZURE_VAULT_URL:-}" ]]      && die "AZURE_VAULT_URL is not set."
[[ -z "${AZURE_SECRET_NAME:-}" ]]    && die "AZURE_SECRET_NAME is not set."

AZURE_VAULT_URL="${AZURE_VAULT_URL%/}"

log "Target Key Vault : ${AZURE_VAULT_URL}"
log "Secret name      : ${AZURE_SECRET_NAME}"

# ----------------------------------------------------------
# Write the client secret to a temp file so it is not
# exposed as a curl command-line argument (visible in
# `ps aux`). The `--data-urlencode "key@file"` form reads
# the value from the file and URL-encodes it automatically.
# The trap ensures cleanup even on error or signal.
# ----------------------------------------------------------
CRED_FILE=$(mktemp)
chmod 600 "${CRED_FILE}"
trap 'rm -f "${CRED_FILE}"' EXIT INT TERM

printf '%s' "${AZURE_CLIENT_SECRET}" > "${CRED_FILE}"

# ----------------------------------------------------------
# Obtain Azure AD bearer token (client credentials flow)
# ----------------------------------------------------------
log "Acquiring Azure AD access token..."

TOKEN_RESPONSE=$(curl -sf \
    --max-time 15 \
    -X POST \
    "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
    --data-urlencode "scope=https://vault.azure.net/.default" \
    --data-urlencode "client_secret@${CRED_FILE}") \
    || die "Failed to obtain Azure AD token."

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty') \
    || die "Failed to parse Azure AD token response."

[[ -z "${ACCESS_TOKEN}" ]] && die "Azure AD returned an empty access token."
log "Azure AD token acquired (token not logged)."

# ----------------------------------------------------------
# Build the Key Vault secret payload.
# Secret value is read from stdin via `jq -Rs` to avoid
# passing it as a jq --arg (which would appear in ps).
# ----------------------------------------------------------
SECRET_PAYLOAD=$(printf '%s' "${SECRET_VALUE}" | jq -Rs '{"value": .}')

[[ -n "${AZURE_SECRET_CONTENT_TYPE:-}" ]] && \
    SECRET_PAYLOAD=$(echo "${SECRET_PAYLOAD}" | jq --arg ct "${AZURE_SECRET_CONTENT_TYPE}" '.contentType = $ct')

[[ -n "${AZURE_SECRET_EXPIRES:-}" ]] && \
    SECRET_PAYLOAD=$(echo "${SECRET_PAYLOAD}" | jq --argjson e "${AZURE_SECRET_EXPIRES}" '.attributes.exp = $e')

# ----------------------------------------------------------
# Write secret to Azure Key Vault via REST API
# ----------------------------------------------------------
log "Writing secret to Azure Key Vault via REST API..."

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    -X PUT \
    "${AZURE_VAULT_URL}/secrets/${AZURE_SECRET_NAME}?api-version=7.4" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${SECRET_PAYLOAD}")

case "${HTTP_STATUS}" in
    200|201) log "Secret written successfully (HTTP ${HTTP_STATUS})." ;;
    *)       die "Key Vault REST API returned unexpected HTTP status: ${HTTP_STATUS}." ;;
esac

log "Sync complete: secret written to Azure Key Vault '${AZURE_SECRET_NAME}'."
