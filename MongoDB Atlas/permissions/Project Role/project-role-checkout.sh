#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkout Script (Project Role)
# =============================================================================
# Purpose   : Grants a JIT project-level role to an Atlas user.
#             Handles two cases:
#               a) User is not yet in the project → add them with the role
#               b) User is already in the project → append the role atomically
#             Called by the Britive Access Broker when a user checks out
#             a project-role profile.
#
# Auth      : MongoDB Atlas OAuth 2.0 (client_credentials grant).
#             Requires a Service Account with Project Owner scope.
#
# Flow      : Obtain token → POST user to project (handles existing user) →
#             If already in project: look up user ID → add role via :addRole
#
# Variables : Substituted by the Britive Access Broker before execution.
#   {{client_id}}      - Atlas OAuth2 Service Account client ID
#   {{client_secret}}  - Atlas OAuth2 Service Account client secret
#   {{project_id}}     - MongoDB Atlas project (group) ID
#   {{atlas_username}} - Atlas username (usually the user's email address)
#   {{project_role}}   - Project role to grant (e.g. GROUP_READ_ONLY,
#                        GROUP_DATA_ACCESS_READ_WRITE, GROUP_OWNER)
#
# Exit codes:
#   0 - Role granted successfully
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
ATLAS_USERNAME="{{atlas_username}}"
PROJECT_ROLE="{{project_role}}"
BASE_URL="https://cloud.mongodb.com"

# ---------------------------------------------------------------------------
# Temporary files — unique per invocation to prevent concurrent session races.
# Two files used: one for the initial add, one for subsequent role operations.
# ---------------------------------------------------------------------------
TMPFILE_ADD=$(mktemp)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE_ADD" "$TMPFILE"' EXIT

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
# Step 2: Attempt to add the user to the project with the requested role.
# A 400 with errorCode USER_ALREADY_IN_GROUP means the user is already a
# project member — we handle that by using the :addRole endpoint instead.
# Any other non-2xx response is a real error.
# ---------------------------------------------------------------------------
echo "INFO: Adding '${ATLAS_USERNAME}' to project '${PROJECT_ID}' with role '${PROJECT_ROLE}'..."

ADD_RESP=$(curl -s -o "${TMPFILE_ADD}" -w "%{http_code}" -X POST \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/users" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${ATLAS_USERNAME}\", \"roles\": [\"${PROJECT_ROLE}\"]}")

if [[ "${ADD_RESP}" -ge 200 && "${ADD_RESP}" -lt 300 ]]; then
  echo "SUCCESS: Added '${ATLAS_USERNAME}' to project with role '${PROJECT_ROLE}'."
  exit 0
fi

if [[ "${ADD_RESP}" -eq 400 ]]; then
  ERROR_CODE=$(jq -r '.errorCode // empty' "${TMPFILE_ADD}")
  if [ "${ERROR_CODE}" = "USER_ALREADY_IN_GROUP" ]; then
    echo "INFO: User is already a project member — will append role via :addRole endpoint."
  else
    echo "ERROR: HTTP 400 adding user to project — ${ERROR_CODE}."
    echo "Response: $(cat "${TMPFILE_ADD}")"
    exit 1
  fi
else
  echo "ERROR: Failed to add user to project — HTTP ${ADD_RESP}."
  echo "Response: $(cat "${TMPFILE_ADD}")"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: User already exists in the project — look up their internal user ID
# so we can use the atomic :addRole endpoint.
# ---------------------------------------------------------------------------
echo "INFO: Looking up user ID for '${ATLAS_USERNAME}' in project '${PROJECT_ID}'..."

USER_LOOKUP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/users?username=${ATLAS_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*")

if [[ "${USER_LOOKUP_CODE}" -lt 200 || "${USER_LOOKUP_CODE}" -ge 300 ]]; then
  echo "ERROR: User lookup failed with HTTP ${USER_LOOKUP_CODE}."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi

USER_ID=$(jq -r '.results[0].id // empty' "${TMPFILE}")

if [ -z "${USER_ID}" ]; then
  echo "ERROR: Could not find user '${ATLAS_USERNAME}' in project '${PROJECT_ID}'."
  exit 1
fi

echo "INFO: Found user ID '${USER_ID}'."

# ---------------------------------------------------------------------------
# Step 4: Atomically add the project role using the :addRole endpoint.
# A 409 means the user already has the role — treated as success (idempotent).
# ---------------------------------------------------------------------------
echo "INFO: Adding role '${PROJECT_ROLE}' to existing project member '${ATLAS_USERNAME}'..."

ADD_ROLE_RESP=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X POST \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/users/${USER_ID}:addRole" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
  -H "Content-Type: application/json" \
  -d "{\"groupRoles\": [\"${PROJECT_ROLE}\"]}")

if [[ "${ADD_ROLE_RESP}" -ge 200 && "${ADD_ROLE_RESP}" -lt 300 ]]; then
  echo "SUCCESS: Granted project role '${PROJECT_ROLE}' to '${ATLAS_USERNAME}'."
elif [[ "${ADD_ROLE_RESP}" -eq 409 ]]; then
  # User already holds this role — idempotent, not an error
  echo "SUCCESS: User '${ATLAS_USERNAME}' already has role '${PROJECT_ROLE}' — no change needed."
else
  echo "ERROR: :addRole failed with HTTP ${ADD_ROLE_RESP}."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi
