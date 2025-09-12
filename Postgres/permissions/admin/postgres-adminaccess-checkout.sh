#!/bin/bash

# PostgreSQL Admin Access Grant Script
# Purpose: Creates a temporary PostgreSQL user with admin privileges for just-in-time access
# Usage: user=<email> svc_user=<service_user> svc_password=<service_password> db_host=<host> db_name=<database> ./postgres-adminaccess-checkout.sh

# Enable strict error handling
set -euo pipefail

# Error cleanup function
cleanup_on_error() {
    local exit_code=$?
    echo "ERROR: Script failed with exit code $exit_code" >&2
    # Attempt to clean up partially created user if possible
    if [[ -n "${PS_USER:-}" && -n "${SVC_USER:-}" && -n "${SVC_PASS:-}" && -n "${DB_HOST:-}" && -n "${DB_NAME:-}" ]]; then
        echo "Attempting to clean up potentially created user: $PS_USER" >&2
        PGPASSWORD="$SVC_PASS" psql -U "$SVC_USER" -p 5432 -h "$DB_HOST" -d "$DB_NAME" -c "DROP USER IF EXISTS $PS_USER;" 2>/dev/null || true
    fi
    exit $exit_code
}

# Set up error trap
trap cleanup_on_error ERR

# Validate required environment variables
for var in user svc_user svc_password db_host db_name; do
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

# Validate inputs and check tools
[[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { echo "ERROR: Invalid DB_NAME: $DB_NAME" >&2; exit 1; }
for tool in psql tr; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: Required tool not found: $tool" >&2; exit 1; }
done

# Generate secure temporary password
PS_PASS=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 16 2>/dev/null)
[[ -z "$PS_PASS" ]] && { echo "ERROR: Failed to generate password" >&2; exit 1; }

# Test database connectivity with service account
export PGPASSWORD="${SVC_PASS}"
if ! psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME with service account $SVC_USER" >&2
    exit 1
fi

# Create or recreate the PostgreSQL user
echo "Creating PostgreSQL user: $PS_USER"
psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" <<EOF
DO \$\$
BEGIN
   -- Drop user if already exists
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE rolname = '${PS_USER}'
   ) THEN
      -- Terminate any existing sessions for this user
      PERFORM pg_terminate_backend(pid) 
      FROM pg_stat_activity 
      WHERE usename = '${PS_USER}' AND pid <> pg_backend_pid();
      
      DROP ROLE ${PS_USER};
      RAISE NOTICE 'Existing user % dropped', '${PS_USER}';
   END IF;
   
   -- Create new user
   CREATE USER ${PS_USER} WITH PASSWORD '${PS_PASS}';
   RAISE NOTICE 'User % created successfully', '${PS_USER}';
END
\$\$;
EOF

# Verify user was created
if ! psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" -c "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '${PS_USER}';" | grep -q "1 row"; then
    echo "ERROR: Failed to create user $PS_USER" >&2
    exit 1
fi

# Grant admin privileges on the database
echo "Granting admin privileges to user: $PS_USER"
if ! psql -U "${SVC_USER}" -p 5432 -h "${DB_HOST}" -d "${DB_NAME}" -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${PS_USER};"; then
    echo "ERROR: Failed to grant privileges to user $PS_USER" >&2
    exit 1
fi

# Test new user connection
export PGPASSWORD="$PS_PASS"
if ! psql -U "$PS_USER" -p 5432 -h "$DB_HOST" -d "$DB_NAME" -c "SELECT current_user;" >/dev/null 2>&1; then
    echo "ERROR: Failed to verify new user connection for $PS_USER" >&2
    exit 1
fi

echo "SUCCESS: User $PS_USER created and granted admin privileges on $DB_NAME."
echo ""
echo "Connection details:"
echo "PGPASSWORD=$PS_PASS psql -p 5432 -h $DB_HOST -U $PS_USER -d $DB_NAME"