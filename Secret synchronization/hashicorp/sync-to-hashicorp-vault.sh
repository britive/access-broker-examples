#!/usr/bin/env bash
# ============================================================
# Britive Broker → HashiCorp Vault Secret Synchronization
# ============================================================
# Writes a secret value to a HashiCorp Vault KV secret.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Supports both KV v1 and KV v2 engines. Defaults to KV v2.
#
# Prerequisites:
#   - Vault CLI (vault) installed and on PATH
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE        – The secret value to write
#   VAULT_ADDR          – HashiCorp Vault server address
#                         e.g. https://vault.example.com:8200
#   VAULT_TOKEN         – Vault token with write access
#   VAULT_SECRET_PATH   – KV path to write to
#                         e.g. secret/my-app/database
#   VAULT_SECRET_KEY    – Key name within the KV secret
#                         e.g. password
#
# Optional env vars:
#   VAULT_NAMESPACE     – Vault namespace (HCP Vault / Enterprise)
#   VAULT_KV_VERSION    – KV engine version: "1" or "2" (default: 2)
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
[[ -z "${VAULT_TOKEN:-}" ]]       && die "VAULT_TOKEN is not set."
[[ -z "${VAULT_SECRET_PATH:-}" ]] && die "VAULT_SECRET_PATH is not set."
[[ -z "${VAULT_SECRET_KEY:-}" ]]  && die "VAULT_SECRET_KEY is not set."

VAULT_KV_VERSION="${VAULT_KV_VERSION:-2}"
[[ "${VAULT_KV_VERSION}" != "1" && "${VAULT_KV_VERSION}" != "2" ]] \
    && die "VAULT_KV_VERSION must be '1' or '2', got: ${VAULT_KV_VERSION}"

log "Vault address   : ${VAULT_ADDR}"
log "Vault KV path   : ${VAULT_SECRET_PATH}"
log "Vault KV key    : ${VAULT_SECRET_KEY}"
log "KV version      : ${VAULT_KV_VERSION}"

[[ -n "${VAULT_NAMESPACE:-}" ]] && export VAULT_NAMESPACE

# ----------------------------------------------------------
# Write secret to HashiCorp Vault.
# The trailing `=-` syntax tells the Vault CLI to read the
# value for VAULT_SECRET_KEY from stdin, preventing the
# secret from appearing as a process argument in `ps aux`.
# ----------------------------------------------------------
log "Writing secret to HashiCorp Vault (KV v${VAULT_KV_VERSION})..."

VAULT_CLI_ARGS=()
[[ "${VAULT_SKIP_VERIFY:-false}" == "true" ]] && VAULT_CLI_ARGS+=("-tls-skip-verify")

if [[ "${VAULT_KV_VERSION}" == "2" ]]; then
    printf '%s' "${SECRET_VALUE}" \
        | vault kv put "${VAULT_CLI_ARGS[@]}" \
            "${VAULT_SECRET_PATH}" \
            "${VAULT_SECRET_KEY}=-" \
        || die "vault kv put failed."
else
    printf '%s' "${SECRET_VALUE}" \
        | vault write "${VAULT_CLI_ARGS[@]}" \
            "${VAULT_SECRET_PATH}" \
            "${VAULT_SECRET_KEY}=-" \
        || die "vault write failed."
fi

log "Sync complete: secret written to Vault path '${VAULT_SECRET_PATH}' key '${VAULT_SECRET_KEY}'."
