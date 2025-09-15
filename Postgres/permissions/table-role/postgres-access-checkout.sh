#!/bin/bash

# PostgreSQL Role Grant Script
# Purpose: Grants a specific role to a PostgreSQL user for table/schema access
# Usage: user=<email> svc_user=<service_user> svc_password=<service_password> db_host=<host> db_name=<database> role_name=<role> ./postgres-access-checkout.sh

# Enable strict error handling
set -euo pipefail

# Validate required environment variables
for var in user svc_user svc_password db_host db_name role_name; do
    [[ -z "${!var:-}" ]] && { echo "ERROR: '$var' environment variable is required" >&2; exit 1; }
done

# Extract and sanitize username from email
PS_USER=${user%%@*}           # Remove domain part
PS_USER=${PS_USER//[^a-zA-Z0-9]/}  # Remove special characters
[[ -z "$PS_USER" || ! "$PS_USER" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]] && {
    echo "ERROR: Invalid username generated from: $user" >&2; exit 1; }

# Set service account credentials
SVC_USER=${svc_user}
SVC_PASS=${svc_password}
DB_HOST=${db_host}
DB_NAME=${db_name}
ROLE_NAME=${role_name}

# Validate inputs and check tools
[[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { echo "ERROR: Invalid DB_NAME: $DB_NAME" >&2; exit 1; }
[[ ! "$ROLE_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && { echo "ERROR: Invalid ROLE_NAME: $ROLE_NAME" >&2; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "ERROR: Required tool not found: psql" >&2; exit 1; }

# Test database connectivity with service account
export PGPASSWORD="${SVC_PASS}"
if ! psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME with service account $SVC_USER" >&2
    exit 1
fi

# Check if the role exists
ROLE_EXISTS=$(psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$ROLE_NAME';" | tr -d " \t\n\r")

if [[ "$ROLE_EXISTS" == "0" ]]; then
    echo "ERROR: Role $ROLE_NAME does not exist in database $DB_NAME" >&2
    exit 1
fi

# Check if the user exists
USER_EXISTS=$(psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$PS_USER';" | tr -d " \t\n\r")

if [[ "$USER_EXISTS" == "0" ]]; then
    echo "ERROR: User $PS_USER does not exist in database $DB_NAME. User must be created first." >&2
    exit 1
fi

# Check if user already has the role
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

# Grant the role to the user
echo "Granting role $ROLE_NAME to user $PS_USER"
if ! psql -h "$DB_HOST" -p 5432 -U "$SVC_USER" -d "$DB_NAME" -c "GRANT $ROLE_NAME TO $PS_USER;"; then
    echo "ERROR: Failed to grant role $ROLE_NAME to user $PS_USER" >&2
    exit 1
fi

# Verify the role was successfully granted
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
