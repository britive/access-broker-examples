#!/bin/bash

# PostgreSQL Admin Access Revoke Script
# Purpose: Revokes admin privileges and removes temporary PostgreSQL user
# Usage: user=<email> svc_user=<service_user> svc_password=<service_password> host=<host> db_name=<database> ./postgres-adminaccess-checkin.sh

# Enable strict error handling
set -euo pipefail

# Validate required environment variables
for var in BRITIVE_USER svc_user svc_password db_host db_name; do
    [[ -z "${!var:-}" ]] && { echo "ERROR: '$var' environment variable is required" >&2; exit 1; }
done

# Extract and sanitize username from email
PS_USER=${BRITIVE_USER%%@*}           # Remove domain part
PS_USER=${PS_USER//[^a-zA-Z0-9]/}  # Remove special characters
[[ -z "$PS_USER" || ! "$PS_USER" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]] && {
    echo "ERROR: Invalid username generated from: $BRITIVE_USER" >&2; exit 1; }

# Set service account credentials
SVC_USER=${svc_user}
SVC_PASS=${svc_password}
DB_HOST=${db_host}
DB_NAME=${db_name}

# Validate inputs and check tools
[[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { echo "ERROR: Invalid DB_NAME: $DB_NAME" >&2; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "ERROR: Required tool not found: psql" >&2; exit 1; }

# Test database connectivity with service account
export PGPASSWORD="${SVC_PASS}"
if ! psql -p 5432 -h "${DB_HOST}" -U "${SVC_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME with service account $SVC_USER" >&2
    exit 1
fi

echo "Revoking admin access and deleting user: $PS_USER"

# Check if user exists before attempting to drop
USER_EXISTS=$(psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$PS_USER';" | tr -d " \t\n\r")

if [[ "$USER_EXISTS" == "0" ]]; then
    echo "User $PS_USER was not found (already removed or never existed)"
    exit 0
fi

# Revoke privileges and drop user
echo "Revoking privileges from user: $PS_USER"
if ! psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" -c "REVOKE ALL PRIVILEGES ON DATABASE $DB_NAME FROM $PS_USER;"; then
    echo "WARNING: Failed to revoke privileges from user $PS_USER (user may not have had privileges)" >&2
fi

# Terminate any active sessions for this user before dropping
echo "Terminating active sessions for user: $PS_USER"
psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" <<EOF
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE usename = '${PS_USER}' AND pid <> pg_backend_pid();
EOF

# Drop the user
echo "Dropping user: $PS_USER"
if ! psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" -c "DROP USER $PS_USER;"; then
    echo "ERROR: Failed to drop user $PS_USER" >&2
    exit 1
fi

# Verify user was dropped
USER_EXISTS_AFTER=$(psql -p 5432 -h "$DB_HOST" -U "$SVC_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$PS_USER';" | tr -d " \t\n\r")

if [[ "$USER_EXISTS_AFTER" != "0" ]]; then
    echo "ERROR: User $PS_USER still exists after drop attempt" >&2
    exit 1
fi

echo "SUCCESS: User $PS_USER has been dropped and access revoked."
