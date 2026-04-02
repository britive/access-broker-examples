#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkin Script (Project Role)
# =============================================================================
# Purpose   : Revokes a JIT project-level role from an Atlas user.
#             Handles two cases:
#               a) Removing one of many roles → use atomic :removeRole endpoint
#               b) Last role on the project → remove user from project entirely
#             Called by the Britive Access Broker on checkin or session expiry.
#
# Auth      : MongoDB Atlas OAuth 2.0 (client_credentials grant).
#             Requires a Service Account with Project Owner scope.
#
# Flow      : Obtain token → Look up user ID → Remove role (:removeRole) →
#             If last role: delete user from project
#
# Variables : Substituted by the Britive Access Broker before execution.
#   {{client_id}}      - Atlas OAuth2 Service Account client ID
#   {{client_secret}}  - Atlas OAuth2 Service Account client secret
#   {{project_id}}     - MongoDB Atlas project (group) ID
#   {{atlas_username}} - Atlas username (must match the checkout value)
#   {{project_role}}   - Project role to revoke (must match checkout role)
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
ATLAS_USERNAME="{{atlas_username}}"
PROJECT_ROLE="{{project_role}}"
BASE_URL="https://cloud.mongodb.com"

# ---------------------------------------------------------------------------
# Temporary files — unique per invocation to prevent concurrent session races.
# ---------------------------------------------------------------------------
TMPFILE=$(mktemp)
TMPFILE_DEL=$(mktemp)
trap 'rm -f "$TMPFILE" "$TMPFILE_DEL"' EXIT

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
# Step 2: Look up the user's internal project member ID.
# ---------------------------------------------------------------------------
echo "INFO: Looking up user '${ATLAS_USERNAME}' in project '${PROJECT_ID}'..."

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
  echo "ERROR: User '${ATLAS_USERNAME}' not found in project '${PROJECT_ID}'."
  exit 1
fi

echo "INFO: Found user ID '${USER_ID}' for '${ATLAS_USERNAME}'."

# ---------------------------------------------------------------------------
# Step 3: Remove the JIT role atomically using the :removeRole endpoint.
# A 403 with CANNOT_REMOVE_LAST_GROUP_ROLE means this was the user's only
# project role — in that case, remove them from the project entirely so they
# retain no project access. This matches the ZSP intent.
# ---------------------------------------------------------------------------
echo "INFO: Revoking project role '${PROJECT_ROLE}' from '${ATLAS_USERNAME}'..."

REMOVE_RESP=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X POST \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/users/${USER_ID}:removeRole" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
  -H "Content-Type: application/json" \
  -d "{\"groupRoles\": [\"${PROJECT_ROLE}\"]}")

if [[ "${REMOVE_RESP}" -ge 200 && "${REMOVE_RESP}" -lt 300 ]]; then
  echo "SUCCESS: Revoked project role '${PROJECT_ROLE}' from '${ATLAS_USERNAME}'."
  exit 0
fi

if [[ "${REMOVE_RESP}" -eq 403 ]]; then
  ERROR_CODE=$(jq -r '.errorCode // empty' "${TMPFILE}")
  if [ "${ERROR_CODE}" = "CANNOT_REMOVE_LAST_GROUP_ROLE" ]; then
    # This was their only project role — remove the user from the project entirely
    echo "INFO: Last project role — removing '${ATLAS_USERNAME}' from project entirely."

    DEL_CODE=$(curl -s -o "${TMPFILE_DEL}" -w "%{http_code}" -X DELETE \
      "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/users/${USER_ID}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.atlas.2025-02-19+json, */*")

    if [[ "${DEL_CODE}" -ge 200 && "${DEL_CODE}" -lt 300 ]]; then
      echo "SUCCESS: Removed '${ATLAS_USERNAME}' from project '${PROJECT_ID}'."
    else
      echo "ERROR: Failed to remove user from project — HTTP ${DEL_CODE}."
      echo "Response: $(cat "${TMPFILE_DEL}")"
      exit 1
    fi
  else
    echo "ERROR: :removeRole returned HTTP 403 — ${ERROR_CODE}."
    echo "Response: $(cat "${TMPFILE}")"
    exit 1
  fi
else
  echo "ERROR: :removeRole failed with HTTP ${REMOVE_RESP}."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi
