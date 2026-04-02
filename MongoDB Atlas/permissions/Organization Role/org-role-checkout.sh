#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkout Script (Organization Role)
# =============================================================================
# Purpose   : Adds a JIT organization-level role to an Atlas user.
#             Existing org roles are preserved (additive grant).
#             Called by the Britive Access Broker when a user checks out
#             an org-role profile.
#
# Auth      : MongoDB Atlas OAuth 2.0 (client_credentials grant).
#             Requires a Service Account with Organization Owner scope.
#
# Flow      : Obtain token → Find user in org → Append org role → PATCH
#
# Variables : Read from environment variables injected by the Britive Access Broker.
#   client_id      - Atlas OAuth2 Service Account client ID
#   client_secret  - Atlas OAuth2 Service Account client secret
#   org_id         - MongoDB Atlas organization ID
#   atlas_username - Atlas username (usually the user's email address)
#   org_role       - Org role to grant  (e.g. ORG_READ_ONLY, ORG_MEMBER)
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
# Configuration — read from environment variables set by the Britive broker.
# Never log CLIENT_SECRET.
# ---------------------------------------------------------------------------
CLIENT_ID="${client_id}"
CLIENT_SECRET="${client_secret}"
ORG_ID="${org_id}"
ATLAS_USERNAME="${atlas_username}"
ORG_ROLE="${org_role}"
URL="${url}"
BASE_URL="https://cloud.mongodb.com"

# Validate all required variables are present
MISSING=()
[ -z "${CLIENT_ID}" ]      && MISSING+=("client_id")
[ -z "${CLIENT_SECRET}" ]  && MISSING+=("client_secret")
[ -z "${ORG_ID}" ]         && MISSING+=("org_id")
[ -z "${ATLAS_USERNAME}" ] && MISSING+=("atlas_username")
[ -z "${ORG_ROLE}" ]       && MISSING+=("org_role")
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: Missing required environment variables: ${MISSING[*]}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Temporary file — unique per invocation to prevent concurrent session races.
# ---------------------------------------------------------------------------
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ---------------------------------------------------------------------------
# Step 1: Obtain a short-lived OAuth2 access token.
# Credentials are passed via Basic auth header (not command-line args) to
# avoid exposure in process listings.
# base64 output stripped of newlines for cross-platform compatibility.
# ---------------------------------------------------------------------------
# echo "INFO: Obtaining Atlas OAuth2 token..."

TOKEN=$(curl -s -X POST "${BASE_URL}/api/oauth/token" \
  -H "Authorization: Basic $(printf '%s:%s' "${CLIENT_ID}" "${CLIENT_SECRET}" | base64 | tr -d '\n')" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  -d "grant_type=client_credentials" | jq -r '.access_token') || true

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "ERROR: Failed to obtain access token — verify CLIENT_ID and CLIENT_SECRET."
  exit 1
fi

# echo "INFO: Token obtained successfully."

# ---------------------------------------------------------------------------
# Step 2: Look up the user in the organization to get their internal user ID.
# We do not use curl -f so that HTTP errors produce a readable response body
# rather than a silent non-zero exit.
# ---------------------------------------------------------------------------
# echo "INFO: Looking up user '${ATLAS_USERNAME}' in org '${ORG_ID}'..."

USER_RESP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
  "${BASE_URL}/api/atlas/v2/orgs/${ORG_ID}/users?username=${ATLAS_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*")

if [[ "${USER_RESP_CODE}" -lt 200 || "${USER_RESP_CODE}" -ge 300 ]]; then
  echo "ERROR: User lookup failed with HTTP ${USER_RESP_CODE}."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi

USER_RESP=$(cat "${TMPFILE}")
USER_ID=$(echo "${USER_RESP}" | jq -r '.results[0].id // empty')

if [ -z "${USER_ID}" ]; then
  echo "ERROR: User '${ATLAS_USERNAME}' not found in org '${ORG_ID}'."
  exit 1
fi

# echo "INFO: Found user ID '${USER_ID}' for '${ATLAS_USERNAME}'."

# ---------------------------------------------------------------------------
# Step 3: Append the new org role to the user's existing roles (additive).
# Deduplication prevents stacking duplicate entries on idempotent reruns.
# ---------------------------------------------------------------------------
CURRENT_ROLES=$(echo "${USER_RESP}" | jq -r '[.results[0].roles.orgRoles[]?]')
UPDATED_ROLES=$(echo "${CURRENT_ROLES}" | jq --arg r "${ORG_ROLE}" '. + [$r] | unique')

# ---------------------------------------------------------------------------
# Step 4: PATCH the user with the updated org roles.
# ---------------------------------------------------------------------------
# echo "INFO: Granting org role '${ORG_ROLE}' to '${ATLAS_USERNAME}'..."

HTTP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X PATCH \
  "${BASE_URL}/api/atlas/v2/orgs/${ORG_ID}/users/${USER_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
  -H "Content-Type: application/json" \
  -d "{\"roles\": {\"orgRoles\": ${UPDATED_ROLES}}}")

if [[ "${HTTP_CODE}" -ge 200 && "${HTTP_CODE}" -lt 300 ]]; then
  echo "{\"url\": \"${URL}\", \"message\": \"Granted org role '${ORG_ROLE}' to '${ATLAS_USERNAME}'.\"}"
else
  echo "ERROR: Org role grant failed with HTTP ${HTTP_CODE}."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi
