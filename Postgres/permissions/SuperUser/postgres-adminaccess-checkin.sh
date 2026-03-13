#!/bin/bash

# PostgreSQL Superuser Access Checkin Script
# Purpose: Revokes SUPERUSER privileges and removes the temporary PostgreSQL user
# Usage: BRITIVE_USER=<email> svc_user=<service_user> svc_password=<password> db_host=<host> db_name=<database> ./postgres-adminaccess-checkin.sh

# Enable strict error handling: exit on error, unset var, or pipe failure
set -euo pipefail

# ---------------------------------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------------------------------
for var in BRITIVE_USER svc_user svc_password db_host db_name; do
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

# ---------------------------------------------------------------------------
# Validate inputs and check required tools
# ---------------------------------------------------------------------------
[[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { echo "ERROR: Invalid DB_NAME: $DB_NAME" >&2; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "ERROR: Required tool not found: psql" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Test database connectivity with the service account before making changes
# ---------------------------------------------------------------------------
export PGPASSWORD="${SVC_PASS}"
if ! psql -p 5432 -h "${DB_HOST}" -U "${SVC_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME with service account $SVC_USER" >&2
    exit 1
fi

echo "Revoking superuser access and deleting user: $PS_USER"

# ---------------------------------------------------------------------------
# Check if the user exists; exit cleanly if already gone (idempotent)
# ---------------------------------------------------------------------------
USER_EXISTS=$(psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$PS_USER';" \
    | tr -d " \t\n\r")

if [[ "$USER_EXISTS" == "0" ]]; then
    echo "User $PS_USER was not found (already removed or never existed)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Remove the user:
#   1. Terminate active sessions (cannot drop a role with open connections)
#   2. Reassign owned objects to the service account (prevents DROP failure —
#      SUPERUSER users can create objects anywhere, so owned objects are likely)
#   3. Drop all remaining privileges and objects
#   4. Drop the role
# ---------------------------------------------------------------------------
psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" <<EOF
-- Terminate any active sessions for this user
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = '${PS_USER}' AND pid <> pg_backend_pid();

-- Transfer any objects owned by the temp user to the service account,
-- then drop all remaining privileges and the role itself
REASSIGN OWNED BY "${PS_USER}" TO "${SVC_USER}";
DROP OWNED BY "${PS_USER}";
DROP ROLE "${PS_USER}";
EOF

# ---------------------------------------------------------------------------
# Verify the user was actually dropped
# ---------------------------------------------------------------------------
USER_EXISTS_AFTER=$(psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$PS_USER';" \
    | tr -d " \t\n\r")

if [[ "$USER_EXISTS_AFTER" != "0" ]]; then
    echo "ERROR: User $PS_USER still exists after drop attempt" >&2
    exit 1
fi

echo "SUCCESS: User $PS_USER has been dropped and access revoked."
