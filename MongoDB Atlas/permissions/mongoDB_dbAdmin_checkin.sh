#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkin Script (dbAdmin)
# =============================================================================
# Purpose : Revokes the elevated 'dbAdmin' role and restores the user to the
#           baseline 'read' role on the target database. Called by the Britive
#           Access Broker when a user checks in (or the session timer expires).
#
# Flow    : Validate inputs → Test Atlas API → PATCH user roles → Verify
#
# Inputs  : All provided as environment variables by the Britive Access Broker
#   mongoDB_public_key   - MongoDB Atlas API public key
#   mongoDB_private_key  - MongoDB Atlas API private key
#   mongoDB_project_id   - MongoDB Atlas project (group) ID
#   mongoDB_username     - Full SSO email of the requesting user
#   mongoDB_database     - (Optional) Target database name. Default: sample_mflix
#   mongoDB_auth_source  - (Optional) Auth source for the user. Default: admin
#   LOG_DIR              - (Optional) Directory for log files.   Default: /tmp
#
# Exit codes:
#   0 - Success
#   1 - Failure (see log for details)
# =============================================================================

# ---------------------------------------------------------------------------
# Logging setup — mirrors the checkout script so both write to the same log
# ---------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_DIR}/mongoDB_dbAdmin_checkout.log"

mkdir -p "$LOG_DIR" 2>/dev/null || {
  LOG_DIR="/tmp"
  LOG_FILE="/tmp/mongoDB_dbAdmin_checkout.log"
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" | tee -a "$LOG_FILE" >&2
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
# Load and validate environment variables
# ---------------------------------------------------------------------------
PUBLIC_KEY="${mongoDB_public_key}"
PRIVATE_KEY="${mongoDB_private_key}"
PROJECT_ID="${mongoDB_project_id}"
RAW_USERNAME="${mongoDB_username}"       # Full SSO email from Britive checkin
DATABASE="${mongoDB_database:-sample_mflix}"
AUTH_SOURCE="${mongoDB_auth_source:-admin}"

MISSING=()
[ -z "$PUBLIC_KEY" ]   && MISSING+=("mongoDB_public_key")
[ -z "$PRIVATE_KEY" ]  && MISSING+=("mongoDB_private_key")
[ -z "$PROJECT_ID" ]   && MISSING+=("mongoDB_project_id")
[ -z "$RAW_USERNAME" ] && MISSING+=("mongoDB_username")

if [ ${#MISSING[@]} -gt 0 ]; then
  log_error "Missing required environment variables: ${MISSING[*]}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Normalize username: same logic as checkout to ensure consistent lookup
# ---------------------------------------------------------------------------
USERNAME="${RAW_USERNAME%%@*}"
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"

if [ -z "$USERNAME" ]; then
  log_error "Could not derive a valid username from '${RAW_USERNAME}'."
  exit 1
fi

log "Starting MongoDB Atlas dbAdmin checkin for user '${USERNAME}' on database '${DATABASE}'..."

# ---------------------------------------------------------------------------
# Step 1: Test connectivity to the MongoDB Atlas API
# ---------------------------------------------------------------------------
log "Testing connection to MongoDB Atlas project '${PROJECT_ID}'..."

TEST_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}" 2>/dev/null)

HTTP_CODE="${TEST_RESPONSE: -3}"

if [ "$HTTP_CODE" != "200" ]; then
  log_error "Connection test failed with HTTP ${HTTP_CODE}. Check API keys and project ID."
  exit 1
fi

log "Connection test succeeded (HTTP ${HTTP_CODE})."

# ---------------------------------------------------------------------------
# Step 2: Restore user to baseline 'read' role, revoking elevated dbAdmin
# The PATCH endpoint replaces all roles, so this effectively removes dbAdmin.
# ---------------------------------------------------------------------------
log "Revoking 'dbAdmin' and restoring 'read' role on '${DATABASE}' for user '${USERNAME}'..."

UPDATE_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request PATCH \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --header "Content-Type: application/json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/${AUTH_SOURCE}/${USERNAME}" \
  --data "{
    \"roles\": [
      {
        \"roleName\": \"read\",
        \"databaseName\": \"${DATABASE}\"
      }
    ]
  }" 2>/dev/null)

UPDATE_HTTP_CODE="${UPDATE_RESPONSE: -3}"

if [ "$UPDATE_HTTP_CODE" != "200" ]; then
  log_error "Role revocation failed with HTTP ${UPDATE_HTTP_CODE} for user '${USERNAME}'."
  exit 1
fi

log "Role revocation succeeded (HTTP ${UPDATE_HTTP_CODE})."

# ---------------------------------------------------------------------------
# Step 3: Verify the roles have been restored to baseline
# ---------------------------------------------------------------------------
log "Verifying roles for user '${USERNAME}'..."

VERIFY_RESPONSE=$(curl -s \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/${AUTH_SOURCE}/${USERNAME}" 2>/dev/null)

log "Current roles for '${USERNAME}':"
echo "$VERIFY_RESPONSE" | jq '.roles' | tee -a "$LOG_FILE"

log "Checkin completed successfully."

# Output a final confirmation to stdout for the Britive broker response
echo "✅ Access revoked. '${USERNAME}' restored to read-only on '${DATABASE}'."
