#!/usr/bin/env bash
# ============================================================
# Lab Setup — Azure Key Vault
# ============================================================
# Creates the minimum Azure resources needed to test the sync
# scripts:
#   - Resource group
#   - Key Vault (RBAC-enabled)
#   - Service principal with 'Key Vault Secrets Officer' role
#   - An initial placeholder secret
#
# Writes credentials + resource names to .env for use by
# test-sync.sh and teardown.sh.
#
# Prerequisites:
#   - Azure CLI installed and authenticated
#     (az login — account needs Contributor + User Access
#      Administrator on the subscription or resource group)
#   - jq installed
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
RG_NAME="${RG_NAME:-britive-lab-rg}"
SP_NAME="${SP_NAME:-britive-lab-sp}"
SECRET_NAME="${SECRET_NAME:-britive-lab-test-secret}"

# Key Vault names must be globally unique, 3–24 chars, lowercase
# alphanumeric and hyphens only. Generate a unique suffix.
UNIQUE_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6 2>/dev/null || echo "lab$(date +%s | tail -c 5)")
KV_NAME="${KV_NAME:-britive-lab-${UNIQUE_SUFFIX}}"

# ── Checks ───────────────────────────────────────────────────
command -v az  &>/dev/null || die "Azure CLI is not installed."
command -v jq  &>/dev/null || die "jq is not installed."

log "Checking Azure login status..."
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"

SUBSCRIPTION_ID=$(az account show --query id --output tsv)
TENANT_ID=$(az account show --query tenantId --output tsv)
log "Subscription: ${SUBSCRIPTION_ID}  Tenant: ${TENANT_ID}"

# If a .env already exists and has a KV_NAME, reuse it to keep teardown clean
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    KV_NAME_SAVED=$(grep '^VAULT_NAME=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo "")
    if [[ -n "${KV_NAME_SAVED}" ]]; then
        KV_NAME="${KV_NAME_SAVED}"
        log "Reusing existing Key Vault name from .env: ${KV_NAME}"
    fi
fi

VAULT_URL="https://${KV_NAME}.vault.azure.net"

# ── Resource group ───────────────────────────────────────────
if az group show --name "${RG_NAME}" &>/dev/null; then
    log "Resource group '${RG_NAME}' already exists — skipping."
else
    log "Creating resource group '${RG_NAME}' in '${AZURE_LOCATION}'..."
    az group create --name "${RG_NAME}" --location "${AZURE_LOCATION}" >/dev/null
fi

# ── Key Vault (RBAC mode) ─────────────────────────────────────
if az keyvault show --name "${KV_NAME}" --resource-group "${RG_NAME}" &>/dev/null; then
    log "Key Vault '${KV_NAME}' already exists — skipping."
else
    log "Creating Key Vault '${KV_NAME}' (RBAC mode)..."
    az keyvault create \
        --name                   "${KV_NAME}" \
        --resource-group         "${RG_NAME}" \
        --location               "${AZURE_LOCATION}" \
        --enable-rbac-authorization true \
        --output none
fi

KV_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.KeyVault/vaults/${KV_NAME}"

# ── Service principal ─────────────────────────────────────────
# Check if SP already exists
SP_APP_ID=$(az ad sp list --display-name "${SP_NAME}" --query '[0].appId' --output tsv 2>/dev/null || echo "")

if [[ -n "${SP_APP_ID}" && "${SP_APP_ID}" != "None" ]]; then
    log "Service principal '${SP_NAME}' already exists (${SP_APP_ID}) — creating new client secret..."
    CLIENT_SECRET=$(az ad app credential reset \
        --id "${SP_APP_ID}" \
        --query 'password' --output tsv)
    SP_OBJECT_ID=$(az ad sp show --id "${SP_APP_ID}" --query id --output tsv)
else
    log "Creating service principal '${SP_NAME}'..."
    SP_JSON=$(az ad sp create-for-rbac \
        --name "${SP_NAME}" \
        --skip-assignment \
        --output json)
    SP_APP_ID=$(echo "${SP_JSON}"    | jq -r '.appId')
    CLIENT_SECRET=$(echo "${SP_JSON}" | jq -r '.password')
    SP_OBJECT_ID=$(az ad sp show --id "${SP_APP_ID}" --query id --output tsv)
fi
log "Service principal: ${SP_APP_ID}  (object: ${SP_OBJECT_ID})"

# ── Role assignment ───────────────────────────────────────────
log "Assigning 'Key Vault Secrets Officer' role to service principal..."
# Retry loop — AAD propagation can take a few seconds
for i in 1 2 3 4 5; do
    az role assignment create \
        --role       "Key Vault Secrets Officer" \
        --assignee   "${SP_OBJECT_ID}" \
        --scope      "${KV_RESOURCE_ID}" \
        --output none 2>/dev/null && break
    log "  Role assignment attempt ${i} failed; retrying in 5 s..."
    sleep 5
done

# Also assign to the currently logged-in user so we can create the initial secret
CURRENT_USER_OID=$(az ad signed-in-user show --query id --output tsv 2>/dev/null || echo "")
if [[ -n "${CURRENT_USER_OID}" ]]; then
    az role assignment create \
        --role     "Key Vault Secrets Officer" \
        --assignee "${CURRENT_USER_OID}" \
        --scope    "${KV_RESOURCE_ID}" \
        --output none 2>/dev/null || true
fi

# ── Initial secret (may need a brief wait for RBAC propagation) ──
log "Creating initial placeholder secret (waiting for RBAC propagation)..."
sleep 10
az keyvault secret set \
    --vault-name "${KV_NAME}" \
    --name        "${SECRET_NAME}" \
    --value       "initial-placeholder" \
    --output none

# ── Write .env ───────────────────────────────────────────────
log "Writing credentials to ${ENV_FILE}..."
cat > "${ENV_FILE}" <<EOF
# Britive Lab — Azure Key Vault
# Generated by setup.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# DO NOT COMMIT THIS FILE

# Service principal credentials (needed by curl variant and PS1)
AZURE_TENANT_ID=${TENANT_ID}
AZURE_CLIENT_ID=${SP_APP_ID}
AZURE_CLIENT_SECRET=${CLIENT_SECRET}

# Target vault and secret
AZURE_VAULT_URL=${VAULT_URL}
AZURE_SECRET_NAME=${SECRET_NAME}

# Resource identifiers (used by teardown.sh)
VAULT_NAME=${KV_NAME}
LAB_RESOURCE_GROUP=${RG_NAME}
LAB_SP_APP_ID=${SP_APP_ID}
LAB_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
EOF
chmod 600 "${ENV_FILE}"

log "Setup complete."
log ""
log "  Key Vault : ${VAULT_URL}"
log "  Secret    : ${SECRET_NAME}"
log "  SP app ID : ${SP_APP_ID}"
log ""
log "Next steps:"
log "  ./test-sync.sh    — run and verify all script variants"
log "  ./teardown.sh     — delete all lab resources when done"
