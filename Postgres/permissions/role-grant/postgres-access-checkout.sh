#!/bin/bash

# PostgreSQL Role Grant Script
# Purpose: Grants a specific pre-existing role to a pre-existing PostgreSQL user
# Usage: BRITIVE_USER=<email> svc_user=<service_user> svc_password=<password> db_host=<host> db_name=<database> role_name=<role> ./postgres-access-checkout.sh
#
# This script does NOT create users. The user must already exist in PostgreSQL.
# Use the superuser or dba-access scripts to create users first.
#
# The service account (svc_user) must have ADMIN OPTION on each role it manages,
# or the CREATEROLE privilege for broader role management.

# Enable strict error handling: exit on error, unset var, or pipe failure
set -euo pipefail

# ---------------------------------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------------------------------
for var in BRITIVE_USER svc_user svc_password db_host db_name role_name; do
    [[ -z "${!var:-}" ]] && { echo "ERROR: '$var' environment variable is required" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Derive PostgreSQL username from the email local-part
# All non-alphanumeric characters are stripped; result must start with a letter
# Example: john.doe@company.com -> johndoe
# ---------------------------------------------------------------------------
PS_USER=${BRITIVE_USER%%@*}
PS_USER=${PS_USER//[^a-zA-Z0-9]/}
[[ -z "$PS_USER" || ! "$PS_USER" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]] && {
    echo "ERROR: Invalid username generated from: $BRITIVE_USER" >&2; exit 1; }

# Set service account credentials into named variables for clarity
SVC_USER=${svc_user}
SVC_PASS=${svc_password}
DB_HOST=${db_host}
DB_NAME=${db_name}
ROLE_NAME=${role_name}

# ---------------------------------------------------------------------------
# Validate inputs and check required tools
# ---------------------------------------------------------------------------
[[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { echo "ERROR: Invalid DB_NAME: $DB_NAME" >&2; exit 1; }
[[ ! "$ROLE_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && { echo "ERROR: Invalid ROLE_NAME: $ROLE_NAME" >&2; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "ERROR: Required tool not found: psql" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Test database connectivity with the service account before making changes
# ---------------------------------------------------------------------------
export PGPASSWORD="${SVC_PASS}"
if ! psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME with service account $SVC_USER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify the target role exists (fail fast with a clear error)
# ---------------------------------------------------------------------------
ROLE_EXISTS=$(psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$ROLE_NAME';" \
    | tr -d " \t\n\r")

if [[ "$ROLE_EXISTS" == "0" ]]; then
    echo "ERROR: Role $ROLE_NAME does not exist in database $DB_NAME" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify the target user exists — this script does not create users
# ---------------------------------------------------------------------------
USER_EXISTS=$(psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$PS_USER';" \
    | tr -d " \t\n\r")

if [[ "$USER_EXISTS" == "0" ]]; then
    echo "ERROR: User $PS_USER does not exist in database $DB_NAME. User must be created first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Check if the user already has the role — exit cleanly if so (idempotent)
# ---------------------------------------------------------------------------
HAS_ROLE=$(psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -t -c "
    SELECT COUNT(*)
    FROM pg_auth_members am
    JOIN pg_roles r1 ON am.member = r1.oid
    JOIN pg_roles r2 ON am.roleid = r2.oid
    WHERE r1.rolname = '$PS_USER' AND r2.rolname = '$ROLE_NAME';
" | tr -d " \t\n\r")

if [[ "$HAS_ROLE" != "0" ]]; then
    echo "User $PS_USER already has role $ROLE_NAME"
    exit 0
fi

# ---------------------------------------------------------------------------
# Grant the role to the user
# ---------------------------------------------------------------------------
echo "Granting role $ROLE_NAME to user $PS_USER"
if ! psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -c "GRANT \"$ROLE_NAME\" TO \"$PS_USER\";"; then
    echo "ERROR: Failed to grant role $ROLE_NAME to user $PS_USER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify the grant was applied
# ---------------------------------------------------------------------------
VERIFY_ROLE=$(psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -t -c "
    SELECT COUNT(*)
    FROM pg_auth_members am
    JOIN pg_roles r1 ON am.member = r1.oid
    JOIN pg_roles r2 ON am.roleid = r2.oid
    WHERE r1.rolname = '$PS_USER' AND r2.rolname = '$ROLE_NAME';
" | tr -d " \t\n\r")

if [[ "$VERIFY_ROLE" == "0" ]]; then
    echo "ERROR: Failed to verify role grant for $PS_USER" >&2
    exit 1
fi

echo "SUCCESS: Role $ROLE_NAME successfully granted to user $PS_USER."
