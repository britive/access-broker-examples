#!/usr/bin/env bash
# ============================================================
# Lab Teardown — AWS Secrets Manager
# ============================================================
# Deletes every resource created by setup.sh:
#   - IAM access keys
#   - IAM user
#   - IAM policy
#   - Secrets Manager secret (force-deleted immediately)
#   - Local .env file
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN: $*" >&2; }

# ── Load resource names ───────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || { warn ".env not found — nothing to clean up."; exit 0; }

# Use admin credentials (not the lab user) for deletion.
# Unset lab user creds so the AWS CLI falls back to the default profile.
# shellcheck disable=SC1090
source "${ENV_FILE}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

IAM_USER="${LAB_IAM_USER:-britive-lab-user}"
POLICY_ARN="${LAB_IAM_POLICY_ARN:-}"

# ── Delete IAM access keys ────────────────────────────────────
log "Deleting IAM access keys for '${IAM_USER}'..."
KEY_IDS=$(aws iam list-access-keys \
    --user-name "${IAM_USER}" \
    --query 'AccessKeyMetadata[].AccessKeyId' \
    --output text 2>/dev/null || echo "")
for KEY_ID in ${KEY_IDS}; do
    aws iam delete-access-key \
        --user-name   "${IAM_USER}" \
        --access-key-id "${KEY_ID}" 2>/dev/null \
        && log "  Deleted key: ${KEY_ID}" \
        || warn "  Could not delete key ${KEY_ID}"
done

# ── Detach policy from user ───────────────────────────────────
if [[ -n "${POLICY_ARN}" ]]; then
    log "Detaching policy from user..."
    aws iam detach-user-policy \
        --user-name  "${IAM_USER}" \
        --policy-arn "${POLICY_ARN}" 2>/dev/null || warn "Policy already detached."
fi

# ── Delete IAM user ───────────────────────────────────────────
log "Deleting IAM user '${IAM_USER}'..."
aws iam delete-user --user-name "${IAM_USER}" 2>/dev/null \
    && log "  User deleted." \
    || warn "  User not found or already deleted."

# ── Delete IAM policy ─────────────────────────────────────────
if [[ -n "${POLICY_ARN}" ]]; then
    log "Deleting IAM policy..."
    aws iam delete-policy --policy-arn "${POLICY_ARN}" 2>/dev/null \
        && log "  Policy deleted." \
        || warn "  Policy not found or already deleted."
fi

# ── Delete Secrets Manager secret ────────────────────────────
log "Deleting Secrets Manager secret '${AWS_SECRET_NAME}'..."
aws secretsmanager delete-secret \
    --secret-id                  "${AWS_SECRET_NAME}" \
    --region                     "${AWS_REGION}" \
    --force-delete-without-recovery \
    2>/dev/null \
    && log "  Secret deleted." \
    || warn "  Secret not found or already deleted."

# ── Remove .env ───────────────────────────────────────────────
rm -f "${ENV_FILE}"
log ".env removed."

log "Teardown complete."
