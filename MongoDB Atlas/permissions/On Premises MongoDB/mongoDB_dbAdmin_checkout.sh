#!/bin/bash
# =============================================================================
# MongoDB On-Premises JIT Access - Checkout Script (dbAdmin)
# =============================================================================
# Purpose   : Elevates an existing MongoDB database user to the 'dbAdmin'
#             role on the target database. Used for on-premises MongoDB
#             instances managed via the Atlas Administration API (Digest auth).
#             Called by the Britive Access Broker when a user checks out
#             the dbAdmin profile.
#
# Auth      : MongoDB Atlas API Digest authentication (public/private key pair).
#             Requires a Project Owner or Project Database Access Admin key.
#
# Flow      : Validate inputs → Test API connectivity → PATCH user roles →
#             Verify and log result
#
# Inputs    : All provided as environment variables by the Britive Access Broker.
#   mongoDB_public_key   - MongoDB Atlas API public key
#   mongoDB_private_key  - MongoDB Atlas API private key (never logged)
#   mongoDB_project_id   - MongoDB Atlas project (group) ID
#   mongoDB_username     - Full SSO email of the requesting user
#   mongoDB_database     - (Optional) Target database name. Default: sample_mflix
#   mongoDB_auth_source  - (Optional) Auth source for the user. Default: admin
#   LOG_DIR              - (Optional) Directory for log output. Default: /tmp
#
# Exit codes:
#   0 - Success
#   1 - Failure (see log for details)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging setup — both stdout and a persistent log file.
# LOG_DIR defaults to /tmp; falls back silently if the configured dir
# cannot be created.
# ---------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_DIR}/mongoDB_dbAdmin_checkout.log"

mkdir -p "${LOG_DIR}" 2>/dev/null || {
  LOG_DIR="/tmp"
  LOG_FILE="/tmp/mongoDB_dbAdmin_checkout.log"
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOG_FILE}"
}

log_error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" | tee -a "${LOG_FILE}" >&2
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Required tool '$cmd' is not installed or not on PATH."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Load and validate environment variables.
# PRIVATE_KEY is intentionally not logged anywhere.
# ---------------------------------------------------------------------------
PUBLIC_KEY="${mongoDB_public_key}"
PRIVATE_KEY="${mongoDB_private_key}"
PROJECT_ID="${mongoDB_project_id}"
RAW_USERNAME="${mongoDB_username}"
DATABASE="${mongoDB_database:-sample_mflix}"
AUTH_SOURCE="${mongoDB_auth_source:-admin}"

MISSING=()
[ -z "${PUBLIC_KEY}" ]    && MISSING+=("mongoDB_public_key")
[ -z "${PRIVATE_KEY}" ]   && MISSING+=("mongoDB_private_key")
[ -z "${PROJECT_ID}" ]    && MISSING+=("mongoDB_project_id")
[ -z "${RAW_USERNAME}" ]  && MISSING+=("mongoDB_username")

if [ "${#MISSING[@]}" -gt 0 ]; then
  log_error "Missing required environment variables: ${MISSING[*]}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Normalize username: extract the local part of the SSO email and strip
# non-alphanumeric characters to meet MongoDB Atlas username requirements.
# Example: "jane.doe@example.com" → "janedoe"
# ---------------------------------------------------------------------------
USERNAME="${RAW_USERNAME%%@*}"           # Drop domain part (@example.com)
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"   # Remove dots, hyphens, plus signs, etc.

if [ -z "${USERNAME}" ]; then
  log_error "Could not derive a valid username from '${RAW_USERNAME}'."
  exit 1
fi

log "Starting dbAdmin checkout for '${USERNAME}' on database '${DATABASE}'..."

# ---------------------------------------------------------------------------
# Step 1: Test connectivity to the MongoDB Atlas API before making changes.
# ---------------------------------------------------------------------------
log "Testing connection to Atlas project '${PROJECT_ID}'..."

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

CONN_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}")

if [ "${CONN_CODE}" != "200" ]; then
  log_error "Connection test failed (HTTP ${CONN_CODE}). Check API keys and project ID."
  log_error "Response: $(cat "${TMPFILE}")"
  exit 1
fi

log "Connection test passed (HTTP ${CONN_CODE})."

# ---------------------------------------------------------------------------
# Step 2: Grant the 'dbAdmin' role.
# The Atlas PATCH endpoint replaces all roles for this user, so only the
# elevated role is set here. Checkin restores the baseline 'read' role.
# ---------------------------------------------------------------------------
log "Granting 'dbAdmin' on '${DATABASE}' to '${USERNAME}'..."

PATCH_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request PATCH \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --header "Content-Type: application/json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/${AUTH_SOURCE}/${USERNAME}" \
  --data "{
    \"roles\": [
      {
        \"roleName\": \"dbAdmin\",
        \"databaseName\": \"${DATABASE}\"
      }
    ]
  }")

if [ "${PATCH_CODE}" != "200" ]; then
  log_error "Role grant failed (HTTP ${PATCH_CODE}) for '${USERNAME}'."
  log_error "Response: $(cat "${TMPFILE}")"
  exit 1
fi

log "Role grant succeeded (HTTP ${PATCH_CODE})."

# ---------------------------------------------------------------------------
# Step 3: Verify the role is now in effect.
# ---------------------------------------------------------------------------
log "Verifying active roles for '${USERNAME}'..."

VERIFY_RESPONSE=$(curl -s \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/${AUTH_SOURCE}/${USERNAME}")

log "Current roles for '${USERNAME}':"
echo "${VERIFY_RESPONSE}" | jq '.roles' | tee -a "${LOG_FILE}"

log "Checkout completed successfully."
