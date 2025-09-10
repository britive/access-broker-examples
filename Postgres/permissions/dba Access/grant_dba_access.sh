#!/bin/bash

# PostgreSQL DBA Access Grant Script
# Purpose: Creates a temporary PostgreSQL user with DBA privileges for just-in-time access
# Usage: SECRET_NAME=<secret> USER_EMAIL=<email> DB_NAME=<database> ./grant_dba_access.sh

# Enable strict error handling
set -euo pipefail

# Error cleanup function
cleanup_on_error() {
    local exit_code=$?
    # Attempt to clean up partially created user if possible
    if [[ -n "${PGHOST:-}" && -n "${PGUSER:-}" && -n "${PGPASSWORD:-}" && -n "${DB_NAME:-}" && -n "${DB_USER:-}" ]]; then
        psql -d "$DB_NAME" -c "DROP ROLE IF EXISTS \"$DB_USER\";" 2>/dev/null || true
    fi
    exit $exit_code
}

# Set up error trap
trap cleanup_on_error ERR

# Validate required environment variables
if [[ -z "${SECRET_NAME:-}" ]]; then
    echo "ERROR: SECRET_NAME environment variable is required"
    exit 1
fi

if [[ -z "${USER_EMAIL:-}" ]]; then
    echo "ERROR: USER_EMAIL environment variable is required"
    exit 1
fi

if [[ -z "${DB_NAME:-}" ]]; then
    echo "ERROR: DB_NAME environment variable is required"
    exit 1
fi

# Validate email format
if [[ ! "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "ERROR: USER_EMAIL format is invalid: $USER_EMAIL"
    exit 1
fi

# Validate database name format
if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: DB_NAME contains invalid characters: $DB_NAME"
    exit 1
fi

# Check required tools are available
for tool in aws jq psql openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool not found: $tool"
        exit 1
    fi
done

# Get database credentials from AWS Secrets Manager
if ! CREDS_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text 2>/dev/null); then
    echo "ERROR: Failed to retrieve secret from AWS Secrets Manager: $SECRET_NAME"
    exit 1
fi

# Validate JSON and extract credentials
if ! echo "$CREDS_JSON" | jq empty 2>/dev/null; then
    echo "ERROR: Invalid JSON received from AWS Secrets Manager"
    exit 1
fi

export PGHOST=$(echo "$CREDS_JSON" | jq -r .host)
export PGPORT=$(echo "$CREDS_JSON" | jq -r .port)
export PGUSER=$(echo "$CREDS_JSON" | jq -r .username)
export PGPASSWORD=$(echo "$CREDS_JSON" | jq -r .password)

# Validate extracted credentials
if [[ -z "$PGHOST" || "$PGHOST" == "null" ]]; then
    echo "ERROR: Database host not found in credentials"
    exit 1
fi

if [[ -z "$PGPORT" || "$PGPORT" == "null" || ! "$PGPORT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid database port in credentials"
    exit 1
fi

if [[ -z "$PGUSER" || "$PGUSER" == "null" ]]; then
    echo "ERROR: Database username not found in credentials"
    exit 1
fi

if [[ -z "$PGPASSWORD" || "$PGPASSWORD" == "null" ]]; then
    echo "ERROR: Database password not found in credentials"
    exit 1
fi

# Generate database username from email
DB_USER=$(echo "${USER_EMAIL%@*}" | tr "." "_" | tr "-" "_")

# Validate generated username
if [[ ! "$DB_USER" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: Generated username contains invalid characters: $DB_USER"
    exit 1
fi

# Generate secure temporary password
if ! TEMP_PASSWORD=$(openssl rand -base64 32); then
    echo "ERROR: Failed to generate temporary password"
    exit 1
fi

# Test database connectivity
if ! psql -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME"
    exit 1
fi

# Create or update user with DBA privileges
psql -d "$DB_NAME" <<EOF
DO \$\$
BEGIN
   IF EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}'
   ) THEN
      DROP ROLE ${DB_USER};
   END IF;
   
   CREATE ROLE ${DB_USER} LOGIN PASSWORD '${TEMP_PASSWORD}';
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
GRANT pg_monitor TO ${DB_USER};
GRANT pg_signal_backend TO ${DB_USER};
EOF

# Output connection configuration
cat <<EOF
{
  "Servers": {
    "1": {
      "Name": "$DB_USER@$PGHOST",
      "Group": "AWS RDS",
      "Host": "$PGHOST",
      "Port": $PGPORT,
      "MaintenanceDB": "$DB_NAME",
      "Username": "$DB_USER",
      "SSLMode": "prefer",
      "Password": "$TEMP_PASSWORD"
    }
  }
}
EOF