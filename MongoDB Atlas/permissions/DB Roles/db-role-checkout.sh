#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - Checkout Script (Database Role)
# =============================================================================
# Purpose   : Grants a JIT database role to an Atlas database user.
#             The username is derived from the user's SSO email address.
#             If the database user does not yet exist, it is created with a
#             one-time local password that is returned to the user via Britive.
#             If the user already exists, the JIT role is appended to their
#             existing roles so that any baseline access is preserved.
#             Called by the Britive Access Broker when a user checks out
#             a database-role profile.
#
# Auth      : MongoDB Atlas OAuth 2.0 (client_credentials grant).
#             Requires a Service Account with Project Owner or Project
#             Database Access Admin scope.
#
# Flow      : Obtain token → Derive DB username from email →
#             Check if user exists → Create with password (if new) OR
#             append role (if existing) → PATCH/POST
#
# Variables : Read from environment variables injected by the Britive Access Broker.
#   client_id              - Atlas OAuth2 Service Account client ID
#   client_secret          - Atlas OAuth2 Service Account client secret
#   project_id             - MongoDB Atlas project (group) ID
#   atlas_username         - Full SSO email of the requesting user
#                            (e.g. john.doe@contoso.com → johndoe)
#   db_checkout_role       - Role to grant  (e.g. dbAdmin, readWrite)
#   db_checkout_database   - Target database name (e.g. mydb, admin)
#   db_cluster_host        - (Optional) Atlas cluster hostname for the connection
#                            string shown at checkout. If omitted a placeholder
#                            is used. Format: cluster0.abc12.mongodb.net
#
# Exit codes:
#   0 - Role granted successfully
#   1 - Failure (error message written to stdout for broker capture)
#
# Note on database authentication:
#   MongoDB Atlas Federation (SAML/OIDC SSO) applies only to the Atlas
#   control plane (UI and API). It does NOT work for database connections.
#   Database-level auth uses SCRAM (username/password), X.509, AWS IAM,
#   or LDAP. This script uses SCRAM with a generated local password.
#   Future: replace with LDAP integration when Atlas LDAP is configured.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisite checks — fail immediately with a clear message if tools are
# missing rather than producing cryptic errors mid-execution.
# ---------------------------------------------------------------------------
for cmd in curl jq base64 tr openssl; do
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
RAW_USERNAME="${atlas_username}"   # Full SSO email, e.g. john.doe@contoso.com
DB_ROLE="${db_checkout_role}"
DB_DATABASE="${db_checkout_database}"
CLUSTER_HOST="${db_cluster_host:-<your-cluster>.mongodb.net}"  # Optional; placeholder if not set
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
# Helper: print a ready-to-use mongosh connection command.
# $1 = password (pass empty string for existing users — command will prompt).
# ---------------------------------------------------------------------------
print_connection_info() {
  local password="${1:-}"
  echo ""
  echo "================================================================"
  echo " MongoDB Connection Details"
  echo "================================================================"
  echo " Host     : ${CLUSTER_HOST}"
  echo " Database : ${DB_DATABASE}"
  echo " Username : ${DB_USERNAME}"
  if [ -n "${password}" ]; then
    echo " Password : ${password}"
    echo ""
    echo " Connect  :"
    echo "   mongosh \"mongodb+srv://${CLUSTER_HOST}/${DB_DATABASE}\" \\"
    echo "     --apiVersion 1 \\"
    echo "     --username \"${DB_USERNAME}\" \\"
    echo "     --password \"${password}\" \\"
    echo "     --authenticationDatabase admin"
  else
    echo " Password : (use your existing database password)"
    echo ""
    echo " Connect  :"
    echo "   mongosh \"mongodb+srv://${CLUSTER_HOST}/${DB_DATABASE}\" \\"
    echo "     --apiVersion 1 \\"
    echo "     --username \"${DB_USERNAME}\" \\"
    echo "     --authenticationDatabase admin"
  fi
  echo "================================================================"
  echo ""
}

# ---------------------------------------------------------------------------
# Derive the MongoDB database username from the SSO email address.
# Strip the domain and remove any non-alphanumeric characters so the result
# conforms to MongoDB Atlas username requirements.
# Example: palak.chheda@britive.com → palakchheda
# ---------------------------------------------------------------------------
DB_USERNAME="${RAW_USERNAME%%@*}"           # Drop @domain.com
DB_USERNAME="${DB_USERNAME//[^a-zA-Z0-9]/}" # Remove dots, hyphens, etc.

if [ -z "${DB_USERNAME}" ]; then
  echo "ERROR: Could not derive a valid database username from '${RAW_USERNAME}'."
  exit 1
fi

# echo "INFO: Derived database username '${DB_USERNAME}' from '${RAW_USERNAME}'."

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
# Step 2: Check whether the database user already exists.
# A 404 means the user is new and must be created; any other non-2xx is an
# unexpected error.
# ---------------------------------------------------------------------------

LOOKUP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
  "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.atlas.2025-02-19+json, */*")

if [[ "${LOOKUP_CODE}" -ge 200 && "${LOOKUP_CODE}" -lt 300 ]]; then
  # -------------------------------------------------------------------------
  # Step 3a: User exists — append the JIT role to their current roles.
  # Reading current roles first ensures we do not wipe any baseline access.
  # Deduplication prevents stacking duplicate role entries on reruns.
  # -------------------------------------------------------------------------
  # echo "INFO: User exists. Appending role '${DB_ROLE}' on '${DB_DATABASE}'..."

  CURRENT_ROLES=$(jq '.roles // []' "${TMPFILE}")
  UPDATED_ROLES=$(echo "${CURRENT_ROLES}" | jq \
    --arg role "${DB_ROLE}" --arg db "${DB_DATABASE}" \
    '. + [{"roleName": $role, "databaseName": $db}] | unique_by(.roleName + .databaseName)')

  HTTP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X PATCH \
    "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${DB_USERNAME}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
    -H "Content-Type: application/json" \
    -d "{\"roles\": ${UPDATED_ROLES}}")

  if [[ "${HTTP_CODE}" -ge 200 && "${HTTP_CODE}" -lt 300 ]]; then
    echo "SUCCESS: Granted DB role '${DB_ROLE}' on '${DB_DATABASE}' to existing user '${DB_USERNAME}'."
    print_connection_info ""
  else
    echo "ERROR: Role grant failed with HTTP ${HTTP_CODE}."
    echo "Response: $(cat "${TMPFILE}")"
    exit 1
  fi

elif [[ "${LOOKUP_CODE}" -eq 404 ]]; then
  # -------------------------------------------------------------------------
  # Step 3b: User does not exist — create them with a generated local password
  # and the requested JIT role.
  #
  # A cryptographically random password is generated using openssl. It is
  # printed to stdout so Britive can display it to the user — this is the
  # only time it appears; it is never stored or logged by this script.
  #
  # Database auth note: Atlas Federation (SSO) does not apply at the DB
  # connection level. SCRAM (username/password) is used here. Future
  # migration path: Atlas LDAP Integration.
  # -------------------------------------------------------------------------
  
  #echo "INFO: User '${DB_USERNAME}' does not exist — creating with local password..."

  # Generate a 24-character random password (alphanumeric only for compatibility)
  DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)

  HTTP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" -X POST \
    "${BASE_URL}/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.atlas.2025-02-19+json, */*" \
    -H "Content-Type: application/json" \
    -d "{
      \"databaseName\": \"admin\",
      \"username\": \"${DB_USERNAME}\",
      \"password\": \"${DB_PASSWORD}\",
      \"roles\": [{\"roleName\": \"${DB_ROLE}\", \"databaseName\": \"${DB_DATABASE}\"}]
    }")

  if [[ "${HTTP_CODE}" -ge 200 && "${HTTP_CODE}" -lt 300 ]]; then
    echo "SUCCESS: Created database user '${DB_USERNAME}' with role '${DB_ROLE}' on '${DB_DATABASE}'."
    print_connection_info "${DB_PASSWORD}"
    # "NOTE: Password is shown once and never stored. Save it before closing this session."
  else
    echo "ERROR: User creation failed with HTTP ${HTTP_CODE}."
    echo "Response: $(cat "${TMPFILE}")"
    exit 1
  fi

else
  echo "ERROR: Unexpected response (HTTP ${LOOKUP_CODE}) checking for user '${DB_USERNAME}'."
  echo "Response: $(cat "${TMPFILE}")"
  exit 1
fi