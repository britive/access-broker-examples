#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkout Script (Database Role)
# =============================================================================
# Purpose   : Adds a JIT database role to an existing Atlas database user.
#             The role is appended to any pre-existing roles so that baseline
#             access (e.g. read) is preserved during the session.
#             Called by the Britive Access Broker when a user checks out
#             a database-role profile.
#
# Auth      : MongoDB Atlas OAuth 2.0 (client_credentials grant).
#             Requires a Service Account with Project Owner or Project
#             Database Access Admin scope.
#
# Flow      : Obtain token → Fetch current roles → Append JIT role → PATCH
#
# Variables : Substituted by the Britive Access Broker before execution.
#   {{client_id}}              - Atlas OAuth2 Service Account client ID
#   {{client_secret}}          - Atlas OAuth2 Service Account client secret
#   {{project_id}}             - MongoDB Atlas project (group) ID
#   {{db_username}}            - Atlas database username to elevate
#   {{db_checkout_role}}       - Role to grant  (e.g. dbAdmin, readWrite)
#   {{db_checkout_database}}   - Target database name (e.g. mydb, admin)
#
# Exit codes:
#   0 - Role granted successfully
#   1 - Failure (error message written to stdout for broker capture)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisite checks — fail immediately with a clear message if tools are
# missing rather than producing cryptic errors mid-execution.
# ---------------------------------------------------------------------------
for cmd in curl jq base64 tr; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required tool '$cmd' is not installed or not on PATH."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Configuration — values are injected by the Britive broker at runtime.
# Never log CLIENT_SECRET.
# ---------------------------------------------------------------------------
CLIENT_ID="{{client_id}}"
CLIENT_SECRET="{{client_secret}}"
PROJECT_ID="{{project_id}}"
DB_USERNAME="{{db_username}}"
DB_ROLE="{{db_checkout_role}}"
DB_DATABASE="{{db_checkout_database}}"
BASE_URL="https://cloud.mongodb.com"

# ---------------------------------------------------------------------------
# Temporary file for API response bodies — unique per invocation to avoid
# race conditions when multiple broker sessions run concurrently.
# Cleaned up automatically on exit (normal or error).
# ---------------------------------------------------------------------------
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ---------------------------------------------------------------------------
# Step 1: Obtain a short-lived OAuth2 access token.
# Credentials are passed via Basic auth header (not command-line args) to
# avoid exposure in process listings.
# base64 output is stripped of newlines (GNU base64 wraps at 76 chars).
# ---------------------------------------------------------------------------
echo "INFO: Obtaining Atlas OAuth2 token..."

TOKEN=$(curl -s -X POST "${BASE_URL}/api/oauth/token" \
  -H "Authorization: Basic $(printf '%s:%s' "${CLIENT_ID}" "${CLIENT_SECRET}" | base64 | tr -d '\n')" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  -d "grant_type=client_credentials" | jq -r '.access_token') || true

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "ERROR: Failed to obtain access token — verify CLIENT_ID and CLIENT_SECRET."
  exit 1
fi

echo "INFO: Token obtained successfully."

# ---------------------------------------------------------------------------
# Step 2: Fetch the user's current roles so we can append (not replace).
# An additive PATCH preserves any baseline roles the user already holds.
# ---------------------------------------------------------------------------
echo "INFO: Fetching current roles for database user '${DB_USERNAME}'..."

CURRENT=$(curl -s \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*") || true

# Validate we got a parseable roles array back
CURRENT_ROLES=$(echo "${CURRENT}" | jq '.roles // empty') || {
  echo "ERROR: Could not parse roles from response — user '${DB_USERNAME}' may not exist."
  echo "Response: ${CURRENT}"
  exit 1
}

# Append the new role; deduplicate so idempotent re-runs don't stack duplicates
UPDATED_ROLES=$(echo "${CURRENT_ROLES}" | jq \
  --arg role "${DB_ROLE}" --arg db "${DB_DATABASE}" \
  '. + [{"roleName": $role, "databaseName": $db}] | unique_by(.roleName + .databaseName)')

# ---------------------------------------------------------------------------
# Step 3: PATCH the user with the updated roles array.
# ---------------------------------------------------------------------------
echo "INFO: Granting role '${DB_ROLE}' on '${DB_DATABASE}' to '${DB_USERNAME}'..."

HTTP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X PATCH \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
  -H "Content-Type: application/json" \
  -d "{\"roles\": ${UPDATED_ROLES}}")

if [[ "${HTTP_CODE}" -ge 200 && "${HTTP_CODE}" -lt 300 ]]; then
  echo "SUCCESS: Granted DB role '${DB_ROLE}' on '${DB_DATABASE}' to '${DB_USERNAME}'."
else
  echo "ERROR: Role grant failed with HTTP ${HTTP_CODE}."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi
