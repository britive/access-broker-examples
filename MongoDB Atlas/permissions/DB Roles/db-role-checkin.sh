#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkin Script (Database Role)
# =============================================================================
# Purpose   : Removes a JIT database role from an Atlas database user, leaving
#             any other roles the user holds intact.
#             Called by the Britive Access Broker on checkin or session expiry.
#
# Auth      : MongoDB Atlas OAuth 2.0 (client_credentials grant).
#
# Flow      : Obtain token → Fetch current roles → Remove JIT role → PATCH
#
# Variables : Substituted by the Britive Access Broker before execution.
#   {{client_id}}              - Atlas OAuth2 Service Account client ID
#   {{client_secret}}          - Atlas OAuth2 Service Account client secret
#   {{project_id}}             - MongoDB Atlas project (group) ID
#   {{db_username}}            - Atlas database username to demote
#   {{db_checkout_role}}       - Role to revoke (must match the checkout role)
#   {{db_checkout_database}}   - Target database name (must match checkout)
#
# Exit codes:
#   0 - Role revoked successfully
#   1 - Failure (error message written to stdout for broker capture)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisite checks
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
# Temporary file — unique per invocation to prevent concurrent session races.
# ---------------------------------------------------------------------------
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ---------------------------------------------------------------------------
# Step 1: Obtain a short-lived OAuth2 access token.
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
# Step 2: Fetch the user's current roles so we can filter (not replace).
# Removing only the JIT role ensures other roles are preserved.
# ---------------------------------------------------------------------------
echo "INFO: Fetching current roles for database user '${DB_USERNAME}'..."

CURRENT=$(curl -s \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*") || true

CURRENT_ROLES=$(echo "${CURRENT}" | jq '.roles // empty') || {
  echo "ERROR: Could not parse roles from response — user '${DB_USERNAME}' may not exist."
  echo "Response: ${CURRENT}"
  exit 1
}

# Build the roles array with the JIT role removed.
# exact match on both roleName AND databaseName to avoid removing
# roles from other databases with the same name.
REMAINING_ROLES=$(echo "${CURRENT_ROLES}" | jq \
  --arg role "${DB_ROLE}" --arg db "${DB_DATABASE}" \
  '[.[] | select(.roleName != $role or .databaseName != $db)]')

# ---------------------------------------------------------------------------
# Step 3: PATCH the user with the JIT role removed.
# ---------------------------------------------------------------------------
echo "INFO: Revoking role '${DB_ROLE}' on '${DB_DATABASE}' from '${DB_USERNAME}'..."

HTTP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X PATCH \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
  -H "Content-Type: application/json" \
  -d "{\"roles\": ${REMAINING_ROLES}}")

if [[ "${HTTP_CODE}" -ge 200 && "${HTTP_CODE}" -lt 300 ]]; then
  echo "SUCCESS: Revoked DB role '${DB_ROLE}' on '${DB_DATABASE}' from '${DB_USERNAME}'."
else
  echo "ERROR: Role revocation failed with HTTP ${HTTP_CODE}."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi
