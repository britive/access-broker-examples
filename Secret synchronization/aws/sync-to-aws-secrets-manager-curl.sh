#!/usr/bin/env bash
# ============================================================
# Britive Broker → AWS Secrets Manager Secret Synchronization
# (curl / REST API variant)
# ============================================================
# Writes a secret value to AWS Secrets Manager using the AWS
# REST API signed with AWS Signature Version 4 (SigV4).
# No AWS CLI required — only curl, jq, openssl, and xxd.
#
# Intended to run as a Britive broker checkout script.
# The Britive platform injects all required values as
# environment variables before calling this script.
#
# Prerequisites:
#   - curl, jq, openssl, xxd  installed
#
# Required env vars (injected by the Britive broker):
#   SECRET_VALUE          – The secret value to write
#   AWS_ACCESS_KEY_ID     – AWS access key
#   AWS_SECRET_ACCESS_KEY – AWS secret access key
#   AWS_REGION            – AWS region
#   AWS_SECRET_NAME       – Name or ARN of the target secret
#
# Optional env vars:
#   AWS_SESSION_TOKEN     – Required when using temporary creds
#                           (IAM role / STS-assumed credentials)
# ============================================================

set -euo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ----------------------------------------------------------
# Validate required environment variables
# ----------------------------------------------------------
log "Validating environment variables..."

[[ -z "${SECRET_VALUE:-}" ]]          && die "SECRET_VALUE is not set."
[[ -z "${AWS_ACCESS_KEY_ID:-}" ]]     && die "AWS_ACCESS_KEY_ID is not set."
[[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] && die "AWS_SECRET_ACCESS_KEY is not set."
[[ -z "${AWS_REGION:-}" ]]            && die "AWS_REGION is not set."
[[ -z "${AWS_SECRET_NAME:-}" ]]       && die "AWS_SECRET_NAME is not set."

log "Target AWS secret : ${AWS_SECRET_NAME}"
log "AWS region        : ${AWS_REGION}"

# ----------------------------------------------------------
# AWS SigV4 signing helpers
# ----------------------------------------------------------
hmac_sha256() {
    echo -n "$2" \
        | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" \
        | sed 's/^.* //'
}

sha256_hex() {
    echo -n "$1" | openssl dgst -sha256 | sed 's/^.* //'
}

# ----------------------------------------------------------
# Build JSON payloads reading SECRET_VALUE from stdin.
# Using `jq -Rs` reads the secret from stdin rather than
# passing it as a --arg, keeping it out of the process list.
# ----------------------------------------------------------

# Payload for PutSecretValue
PUT_BODY=$(printf '%s' "${SECRET_VALUE}" | jq -Rs \
    --arg name "${AWS_SECRET_NAME}" \
    '{"SecretId": $name, "SecretString": .}')

# Payload for CreateSecret (used only if PutSecretValue returns 400)
CREATE_BODY=$(printf '%s' "${SECRET_VALUE}" | jq -Rs \
    --arg name "${AWS_SECRET_NAME}" \
    '{"Name": $name, "SecretString": .}')

# ----------------------------------------------------------
# Sign and call the AWS Secrets Manager REST API
# ----------------------------------------------------------
sign_and_call() {
    local target="$1"
    local body="$2"

    local service="secretsmanager"
    local host="${service}.${AWS_REGION}.amazonaws.com"
    local endpoint="https://${host}"
    local amz_date
    amz_date="$(date -u '+%Y%m%dT%H%M%SZ')"
    local date_only="${amz_date:0:8}"
    local body_hash
    body_hash=$(sha256_hex "${body}")

    local canon_headers="content-type:application/x-amz-json-1.1\nhost:${host}\nx-amz-date:${amz_date}\n"
    local signed_headers="content-type;host;x-amz-date"

    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
        canon_headers="${canon_headers}x-amz-security-token:${AWS_SESSION_TOKEN}\n"
        signed_headers="${signed_headers};x-amz-security-token"
    fi

    local canon_req="POST\n/\n\n${canon_headers}\n${signed_headers}\n${body_hash}"
    local cred_scope="${date_only}/${AWS_REGION}/${service}/aws4_request"
    local sts="AWS4-HMAC-SHA256\n${amz_date}\n${cred_scope}\n$(sha256_hex "$(echo -e "${canon_req}")")"

    local k_date k_region k_service k_signing signature
    k_date=$(hmac_sha256    "$(printf '%s' "AWS4${AWS_SECRET_ACCESS_KEY}" | xxd -p -c 256)" "${date_only}")
    k_region=$(hmac_sha256  "${k_date}"    "${AWS_REGION}")
    k_service=$(hmac_sha256 "${k_region}"  "${service}")
    k_signing=$(hmac_sha256 "${k_service}" "aws4_request")
    signature=$(hmac_sha256 "${k_signing}" "$(echo -e "${sts}")")

    local auth="AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${cred_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

    local extra_headers=()
    [[ -n "${AWS_SESSION_TOKEN:-}" ]] && extra_headers+=("-H" "x-amz-security-token: ${AWS_SESSION_TOKEN}")

    curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        -X POST "${endpoint}" \
        -H "Content-Type: application/x-amz-json-1.1" \
        -H "Host: ${host}" \
        -H "X-Amz-Date: ${amz_date}" \
        -H "X-Amz-Target: ${target}" \
        -H "Authorization: ${auth}" \
        "${extra_headers[@]}" \
        -d "${body}"
}

log "Writing secret to AWS Secrets Manager via REST API..."

HTTP_STATUS=$(sign_and_call "secretsmanager.PutSecretValue" "${PUT_BODY}")

if [[ "${HTTP_STATUS}" == "200" ]]; then
    log "Secret updated successfully (HTTP 200)."
elif [[ "${HTTP_STATUS}" == "400" ]]; then
    log "Secret not found (400) — attempting CreateSecret..."
    HTTP_STATUS=$(sign_and_call "secretsmanager.CreateSecret" "${CREATE_BODY}")
    [[ "${HTTP_STATUS}" == "200" ]] \
        || die "CreateSecret failed with HTTP ${HTTP_STATUS}."
    log "Secret created successfully (HTTP 200)."
else
    die "PutSecretValue returned unexpected HTTP status: ${HTTP_STATUS}."
fi

log "Sync complete: secret written to AWS Secrets Manager '${AWS_SECRET_NAME}'."
