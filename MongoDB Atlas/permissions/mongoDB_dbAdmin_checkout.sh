#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkout Script (dbAdmin)
# =============================================================================
# Purpose : Elevates a Britive-managed user to the 'dbAdmin' role on the
#           target database. Called by the Britive Access Broker when a user
#           checks out the dbAdmin profile.
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
# Logging setup
# ---------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_DIR}/mongoDB_dbAdmin_checkout.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR" 2>/dev/null || {
  echo "WARNING: Cannot create log directory '$LOG_DIR', falling back to /tmp"
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
RAW_USERNAME="${mongoDB_username}"       # Full SSO email from Britive checkout
DATABASE="${mongoDB_database:-sample_mflix}"
AUTH_SOURCE="${mongoDB_auth_source:-admin}"

# Validate all required variables are present
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
# Normalize username: extract local part of email and strip non-alphanumeric
# characters so it conforms to MongoDB Atlas username requirements.
# Example: "jane.doe@example.com" → "janedoe"
# ---------------------------------------------------------------------------
USERNAME="${RAW_USERNAME%%@*}"          # Drop domain (@example.com)
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"  # Remove dots, hyphens, etc.

if [ -z "$USERNAME" ]; then
  log_error "Could not derive a valid username from '${RAW_USERNAME}'."
  exit 1
fi

log "Starting MongoDB Atlas dbAdmin checkout for user '${USERNAME}' on database '${DATABASE}'..."

# ---------------------------------------------------------------------------
# Step 1: Test connectivity to the MongoDB Atlas API
# ---------------------------------------------------------------------------
log "Testing connection to MongoDB Atlas project '${PROJECT_ID}'..."

TEST_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}")

HTTP_CODE="${TEST_RESPONSE: -3}"

if [ "$HTTP_CODE" != "200" ]; then
  log_error "Connection test failed with HTTP ${HTTP_CODE}. Check API keys and project ID."
  exit 1
fi

log "Connection test succeeded (HTTP ${HTTP_CODE})."

# ---------------------------------------------------------------------------
# Step 2: Elevate user role to dbAdmin on the target database
# The PATCH endpoint replaces all roles for the user, so only the desired
# elevated role is included here. Checkin restores the baseline role.
# ---------------------------------------------------------------------------
log "Granting 'dbAdmin' role on '${DATABASE}' to user '${USERNAME}'..."

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
        \"roleName\": \"dbAdmin\",
        \"databaseName\": \"${DATABASE}\"
      }
    ]
  }")

UPDATE_HTTP_CODE="${UPDATE_RESPONSE: -3}"

if [ "$UPDATE_HTTP_CODE" != "200" ]; then
  log_error "Role update failed with HTTP ${UPDATE_HTTP_CODE} for user '${USERNAME}'."
  exit 1
fi

log "Role update succeeded (HTTP ${UPDATE_HTTP_CODE})."

# ---------------------------------------------------------------------------
# Step 3: Verify the updated roles are in effect
# ---------------------------------------------------------------------------
log "Verifying roles for user '${USERNAME}'..."

VERIFY_RESPONSE=$(curl -s \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/${AUTH_SOURCE}/${USERNAME}")

log "Current roles for '${USERNAME}':"
echo "$VERIFY_RESPONSE" | jq '.roles' | tee -a "$LOG_FILE"

log "Checkout completed successfully."
