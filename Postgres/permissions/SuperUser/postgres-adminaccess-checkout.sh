#!/bin/bash

# PostgreSQL Superuser Access Checkout Script
# Purpose: Creates a temporary PostgreSQL user with SUPERUSER privileges for just-in-time access
# Usage: BRITIVE_USER=<email> svc_user=<service_user> svc_password=<password> db_host=<host> db_name=<database> ./postgres-adminaccess-checkout.sh
#
# The service account (svc_user) must itself have SUPERUSER privilege —
# only a superuser can grant the SUPERUSER attribute to another role.

# Enable strict error handling: exit on error, unset var, or pipe failure
set -euo pipefail

# ---------------------------------------------------------------------------
# Error trap: attempt to drop the partially created user on failure
# ---------------------------------------------------------------------------
cleanup_on_error() {
    local exit_code=$?
    echo "ERROR: Script failed with exit code $exit_code" >&2
    if [[ -n "${PS_USER:-}" && -n "${SVC_USER:-}" && -n "${SVC_PASS:-}" && -n "${DB_HOST:-}" && -n "${DB_NAME:-}" ]]; then
        echo "Attempting to clean up potentially created user: $PS_USER" >&2
        PGPASSWORD="$SVC_PASS" psql -U "$SVC_USER" -p 5432 -h "$DB_HOST" -d "$DB_NAME" \
            -c "DROP USER IF EXISTS \"$PS_USER\";" 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup_on_error ERR

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
for tool in psql tr; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: Required tool not found: $tool" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Generate a cryptographically secure 16-character temporary password
# Using LC_ALL=C ensures tr works correctly regardless of locale
# ---------------------------------------------------------------------------
PS_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 16)
[[ -z "$PS_PASS" ]] && { echo "ERROR: Failed to generate password" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Test database connectivity with the service account before making changes
# ---------------------------------------------------------------------------
export PGPASSWORD="${SVC_PASS}"
if ! psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME with service account $SVC_USER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# If the user already exists, cleanly remove them before recreating:
#   1. Terminate their active sessions
#   2. Reassign owned objects to the service account (prevents DROP failure
#      since SUPERUSER users can create any object in any schema)
#   3. Drop all remaining owned objects and privileges
#   4. Drop the role
# ---------------------------------------------------------------------------
USER_EXISTS=$(psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" -t -c \
    "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '${PS_USER}';" \
    | tr -d " \t\n\r")

if [[ "$USER_EXISTS" != "0" ]]; then
    echo "User $PS_USER already exists — cleaning up before recreating..."
    psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" <<EOF
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = '${PS_USER}' AND pid <> pg_backend_pid();

REASSIGN OWNED BY "${PS_USER}" TO "${SVC_USER}";
DROP OWNED BY "${PS_USER}";
DROP ROLE "${PS_USER}";
EOF
fi

# ---------------------------------------------------------------------------
# Create the temporary user and grant SUPERUSER privilege
# ---------------------------------------------------------------------------
echo "Creating PostgreSQL user: $PS_USER"
psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" \
    -c "CREATE USER \"${PS_USER}\" WITH PASSWORD '${PS_PASS}';"

echo "Granting SUPERUSER privileges to user: $PS_USER"
psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" \
    -c "ALTER USER \"${PS_USER}\" WITH SUPERUSER;"

# ---------------------------------------------------------------------------
# Verify the new user can actually connect (fail fast if something is wrong)
# ---------------------------------------------------------------------------
export PGPASSWORD="$PS_PASS"
if ! psql -U "$PS_USER" -p 5432 -h "$DB_HOST" -d "$DB_NAME" -c "SELECT current_user;" >/dev/null 2>&1; then
    echo "ERROR: Failed to verify new user connection for $PS_USER" >&2
    exit 1
fi

echo "SUCCESS: User $PS_USER created and granted SUPERUSER privileges on $DB_NAME."
echo ""
echo "Connection details:"
echo "PGPASSWORD=$PS_PASS psql -p 5432 -h $DB_HOST -U $PS_USER -d $DB_NAME"
