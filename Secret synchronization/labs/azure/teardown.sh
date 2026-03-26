#!/usr/bin/env bash
# ============================================================
# Lab Teardown — Azure Key Vault
# ============================================================
# Deletes every resource created by setup.sh:
#   - Service principal (app registration)
#   - Resource group (which contains the Key Vault and secret)
#   - Local .env file
#
# Note: Deleting the resource group removes the Key Vault and
# all secrets inside it. Key Vault soft-delete may still keep
# a recoverable copy for 7–90 days (depending on policy);
# this script also purges it when possible.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN: $*" >&2; }

# ── Load resource names ───────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || { warn ".env not found — nothing to clean up."; exit 0; }
# shellcheck disable=SC1090
source "${ENV_FILE}"

RG="${LAB_RESOURCE_GROUP:-britive-lab-rg}"
SP_APP_ID="${LAB_SP_APP_ID:-}"
KV="${VAULT_NAME:-}"

# ── Log in as admin if needed ────────────────────────────────
# Re-use the current az session (should be admin credentials).
az account show >/dev/null 2>&1 \
    || { warn "Not logged in to Azure CLI. Run: az login"; exit 1; }

# ── Delete service principal ──────────────────────────────────
if [[ -n "${SP_APP_ID}" ]]; then
    log "Deleting service principal (app ID: ${SP_APP_ID})..."
    az ad app delete --id "${SP_APP_ID}" 2>/dev/null \
        && log "  Service principal deleted." \
        || warn "  SP not found or already deleted."
fi

# ── Purge soft-deleted Key Vault (if it exists) ───────────────
# Soft-delete keeps the vault recoverable; purge removes it permanently.
if [[ -n "${KV}" ]]; then
    LOCATION=$(az group show --name "${RG}" --query location --output tsv 2>/dev/null || echo "")
    if [[ -n "${LOCATION}" ]]; then
        log "Attempting to purge soft-deleted Key Vault '${KV}'..."
        az keyvault purge --name "${KV}" --location "${LOCATION}" 2>/dev/null \
            || warn "  Vault '${KV}' not in soft-deleted state or already purged."
    fi
fi

# ── Delete resource group ─────────────────────────────────────
log "Deleting resource group '${RG}' (this removes the Key Vault + all secrets)..."
az group delete \
    --name    "${RG}" \
    --yes \
    --no-wait \
    2>/dev/null \
    && log "  Resource group deletion initiated (runs asynchronously)." \
    || warn "  Resource group not found or already deleted."

# ── Remove .env ───────────────────────────────────────────────
rm -f "${ENV_FILE}"
log ".env removed."

log "Teardown complete."
log "(Resource group deletion may still be in progress in the background.)"
