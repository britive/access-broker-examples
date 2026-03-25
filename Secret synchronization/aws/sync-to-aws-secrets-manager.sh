#!/usr/bin/env bash
# ============================================================
# Britive Broker → AWS Secrets Manager Secret Synchronization
# ============================================================
# Writes a secret value to AWS Secrets Manager.
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Prerequisites:
#   - AWS CLI v2 installed and on PATH
#   - AWS credentials available via env vars, instance profile,
#     IRSA, or a named profile (AWS_PROFILE)
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE       – The secret value to write
#   AWS_SECRET_NAME    – Name or ARN of the target secret in
#                        AWS Secrets Manager
#   AWS_REGION         – AWS region where the secret lives
#
# Optional env vars:
#   AWS_PROFILE        – Named AWS CLI profile to use
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
[[ -z "${AWS_SECRET_NAME:-}" ]] && die "AWS_SECRET_NAME is not set."
[[ -z "${AWS_REGION:-}" ]]      && die "AWS_REGION is not set."

log "Target AWS secret : ${AWS_SECRET_NAME}"
log "AWS region        : ${AWS_REGION}"

# ----------------------------------------------------------
# Write secret value to a locked-down temp file.
# AWS CLI supports file:// references for secret-string,
# which avoids the value appearing as a process argument
# visible in `ps aux`.
# The trap ensures cleanup even on error or signal.
# ----------------------------------------------------------
SECRET_FILE=$(mktemp)
chmod 600 "${SECRET_FILE}"
trap 'rm -f "${SECRET_FILE}"' EXIT INT TERM

printf '%s' "${SECRET_VALUE}" > "${SECRET_FILE}"

# ----------------------------------------------------------
# Write secret to AWS Secrets Manager
# ----------------------------------------------------------
log "Writing secret to AWS Secrets Manager..."

AWS_BASE_ARGS=(
    "--region"    "${AWS_REGION}"
    "--output"    "json"
)
[[ -n "${AWS_PROFILE:-}" ]] && AWS_BASE_ARGS=("--profile" "${AWS_PROFILE}" "${AWS_BASE_ARGS[@]}")

# Attempt put-secret-value; if the secret does not exist yet, create it
if aws secretsmanager put-secret-value \
       "${AWS_BASE_ARGS[@]}" \
       --secret-id     "${AWS_SECRET_NAME}" \
       --secret-string "file://${SECRET_FILE}" \
       > /dev/null 2>&1; then
    log "Secret updated successfully."
else
    log "put-secret-value failed — attempting create-secret..."
    aws secretsmanager create-secret \
        "${AWS_BASE_ARGS[@]}" \
        --name          "${AWS_SECRET_NAME}" \
        --secret-string "file://${SECRET_FILE}" \
        > /dev/null \
        || die "Failed to create secret '${AWS_SECRET_NAME}' in AWS Secrets Manager."
    log "Secret created successfully."
fi

log "Sync complete: secret written to AWS Secrets Manager '${AWS_SECRET_NAME}'."
