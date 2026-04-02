#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkin Script (Database Role)
# =============================================================================
# Purpose   : Revokes a JIT database role from an Atlas database user.
#             The username is derived from the user's SSO email address —
#             must use the same derivation logic as the checkout script.
#             Handles two cases:
#               a) User has other roles → remove only the JIT role (PATCH)
#               b) User has no other roles → they were JIT-created, delete them
#             Called by the Britive Access Broker on checkin or session expiry.
#
# Auth      : MongoDB Atlas OAuth 2.0 (client_credentials grant).
#
# Flow      : Obtain token → Derive DB username from email →
#             Fetch current roles → Remove JIT role →
#             If no remaining roles: DELETE user / else: PATCH roles
#
# Variables : Read from environment variables injected by the Britive Access Broker.
#   client_id              - Atlas OAuth2 Service Account client ID
#   client_secret          - Atlas OAuth2 Service Account client secret
#   project_id             - MongoDB Atlas project (group) ID
#   atlas_username         - Full SSO email of the requesting user
#                            (must match the value used at checkout)
#   db_checkout_role       - Role to revoke (must match the checkout role)
#   db_checkout_database   - Target database name (must match checkout)
#
# Exit codes:
#   0 - Role revoked (or user deleted) successfully
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
# Configuration — read from environment variables set by the Britive broker.
# Never log CLIENT_SECRET.
# ---------------------------------------------------------------------------
CLIENT_ID="${client_id}"
CLIENT_SECRET="${client_secret}"
PROJECT_ID="${project_id}"
RAW_USERNAME="${atlas_username}"   # Full SSO email, e.g. palak.chheda@britive.com
DB_ROLE="${db_checkout_role}"
DB_DATABASE="${db_checkout_database}"
BASE_URL="https://cloud.mongodb.com"

# Validate all required variables are present
MISSING=()
[ -z "${CLIENT_ID}" ]     && MISSING+=("client_id")
[ -z "${CLIENT_SECRET}" ] && MISSING+=("client_secret")
[ -z "${PROJECT_ID}" ]    && MISSING+=("project_id")
[ -z "${RAW_USERNAME}" ]  && MISSING+=("atlas_username")
[ -z "${DB_ROLE}" ]       && MISSING+=("db_checkout_role")
[ -z "${DB_DATABASE}" ]   && MISSING+=("db_checkout_database")
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: Missing required environment variables: ${MISSING[*]}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Derive the MongoDB database username — identical logic to checkout so the
# correct user is targeted.
# Example: palak.chheda@britive.com → palakchheda
# ---------------------------------------------------------------------------
DB_USERNAME="${RAW_USERNAME%%@*}"
DB_USERNAME="${DB_USERNAME//[^a-zA-Z0-9]/}"

if [ -z "${DB_USERNAME}" ]; then
  echo "ERROR: Could not derive a valid database username from '${RAW_USERNAME}'."
  exit 1
fi

echo "INFO: Derived database username '${DB_USERNAME}' from '${RAW_USERNAME}'."

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
# Step 2: Fetch the user's current roles.
# ---------------------------------------------------------------------------
echo "INFO: Fetching current roles for database user '${DB_USERNAME}'..."

LOOKUP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*")

if [[ "${LOOKUP_CODE}" -eq 404 ]]; then
  # User is already gone — nothing to revoke, treat as success.
  echo "INFO: Database user '${DB_USERNAME}' does not exist — nothing to revoke."
  exit 0
elif [[ "${LOOKUP_CODE}" -lt 200 || "${LOOKUP_CODE}" -ge 300 ]]; then
  echo "ERROR: Failed to fetch user (HTTP ${LOOKUP_CODE})."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi

# Build the roles array with the JIT role removed.
# Exact match on both roleName AND databaseName to avoid removing roles
# from other databases that happen to share the same role name.
REMAINING_ROLES=$(jq \
  --arg role "${DB_ROLE}" --arg db "${DB_DATABASE}" \
  '[.roles[]? | select(.roleName != $role or .databaseName != $db)]' \
  "${TMPFILE}")

REMAINING_COUNT=$(echo "${REMAINING_ROLES}" | jq 'length')

# ---------------------------------------------------------------------------
# Step 3: Act based on whether the user has any remaining roles.
#
# No remaining roles means this user was created by the checkout script
# solely for this JIT session. Delete them entirely to maintain ZSP —
# a user with no roles is an orphaned credential that serves no purpose.
#
# Remaining roles means the user pre-existed with baseline access.
# Only the JIT role is removed; all other roles are preserved.
# ---------------------------------------------------------------------------
if [[ "${REMAINING_COUNT}" -eq 0 ]]; then
  echo "INFO: No remaining roles after revocation — deleting JIT-created user '${DB_USERNAME}'..."

  DEL_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X DELETE \
    "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.atlas.2025-02-19+json, */*")

  if [[ "${DEL_CODE}" -ge 200 && "${DEL_CODE}" -lt 300 ]]; then
    echo "SUCCESS: Deleted JIT-created database user '${DB_USERNAME}'."
  else
    echo "ERROR: User deletion failed with HTTP ${DEL_CODE}."
    echo "Response: $(cat "${TMPFILE}")"
    exit 1
  fi

else
  echo "INFO: Revoking role '${DB_ROLE}' on '${DB_DATABASE}' — ${REMAINING_COUNT} other role(s) will be preserved..."

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
fi