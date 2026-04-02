#!/usr/bin/env bash
# ============================================================
# Britive Broker → Azure Key Vault Secret Synchronization
# ============================================================
# Writes a secret value to an Azure Key Vault secret.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Prerequisites:
#   - Azure CLI (az) installed, authenticated, and on PATH
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE       – The secret value to write
#   AZURE_VAULT_URL    – Key Vault URL
#                        e.g. https://myvault.vault.azure.net
#   AZURE_SECRET_NAME  – Secret name inside the Key Vault
#
# Optional env vars:
#   AZURE_SECRET_CONTENT_TYPE – Content-type tag (e.g. text/plain)
#   AZURE_SECRET_EXPIRES      – Expiry date/time (ISO 8601)
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
[[ -z "${AZURE_VAULT_URL:-}" ]]   && die "AZURE_VAULT_URL is not set."
[[ -z "${AZURE_SECRET_NAME:-}" ]] && die "AZURE_SECRET_NAME is not set."

VAULT_NAME="$(basename "${AZURE_VAULT_URL%/}")"

log "Target Key Vault : ${AZURE_VAULT_URL}"
log "Secret name      : ${AZURE_SECRET_NAME}"

# ----------------------------------------------------------
# Write secret value to a locked-down temp file.
# `az keyvault secret set --file` reads the value from a
# file rather than a command-line argument, preventing the
# secret from appearing in `ps aux` output.
# The trap ensures cleanup even on error or signal.
# ----------------------------------------------------------
SECRET_FILE=$(mktemp)
chmod 600 "${SECRET_FILE}"
trap 'rm -f "${SECRET_FILE}"' EXIT INT TERM

printf '%s' "${SECRET_VALUE}" > "${SECRET_FILE}"

# ----------------------------------------------------------
# Write secret to Azure Key Vault
# ----------------------------------------------------------
log "Writing secret to Azure Key Vault..."

AZ_ARGS=(
    keyvault secret set
    --vault-name "${VAULT_NAME}"
    --name       "${AZURE_SECRET_NAME}"
    --file       "${SECRET_FILE}"
    --output     none
)

[[ -n "${AZURE_SECRET_CONTENT_TYPE:-}" ]] && AZ_ARGS+=("--content-type" "${AZURE_SECRET_CONTENT_TYPE}")
[[ -n "${AZURE_SECRET_EXPIRES:-}" ]]      && AZ_ARGS+=("--expires"      "${AZURE_SECRET_EXPIRES}")

az "${AZ_ARGS[@]}" || die "az keyvault secret set failed."

log "Sync complete: secret written to Azure Key Vault '${AZURE_SECRET_NAME}'."
