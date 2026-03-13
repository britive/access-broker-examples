#!/bin/bash

# PostgreSQL DBA Access Grant Script
# Purpose: Creates a temporary PostgreSQL user with DBA privileges for just-in-time access
# Usage: BRITIVE_USER=<email> SECRET_NAME=<secret> DB_NAME=<database> ./grant_dba_access.sh
#
# Privileges granted to the temporary user:
#   - ALL PRIVILEGES ON DATABASE (CONNECT, CREATE, TEMP)
#   - pg_monitor              (query pg_stat_* views, read server logs)
#   - pg_signal_backend       (terminate other backend sessions)
#
# The service account stored in Secrets Manager must have:
#   - CREATEROLE
#   - GRANT OPTION on the above privileges so it can delegate them

# Enable strict error handling: exit on error, unset var, or pipe failure
set -euo pipefail

# ---------------------------------------------------------------------------
# Error trap: attempt to drop the partially created user on failure
# ---------------------------------------------------------------------------
cleanup_on_error() {
    local exit_code=$?
    if [[ -n "${PGHOST:-}" && -n "${PGUSER:-}" && -n "${PGPASSWORD:-}" && -n "${DB_NAME:-}" && -n "${DB_USER:-}" ]]; then
        psql -d "$DB_NAME" -c "DROP ROLE IF EXISTS \"$DB_USER\";" 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup_on_error ERR

# ---------------------------------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------------------------------
if [[ -z "${SECRET_NAME:-}" ]]; then
    echo "ERROR: SECRET_NAME environment variable is required" >&2
    exit 1
fi

if [[ -z "${BRITIVE_USER:-}" ]]; then
    echo "ERROR: BRITIVE_USER environment variable is required" >&2
    exit 1
fi

if [[ -z "${DB_NAME:-}" ]]; then
    echo "ERROR: DB_NAME environment variable is required" >&2
    exit 1
fi

# Validate email format
if [[ ! "$BRITIVE_USER" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "ERROR: BRITIVE_USER format is invalid: $BRITIVE_USER" >&2
    exit 1
fi

# Validate database name (alphanumeric, hyphens, underscores only)
if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: DB_NAME contains invalid characters: $DB_NAME" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Check required tools
# ---------------------------------------------------------------------------
for tool in aws jq psql openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool not found: $tool" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Retrieve service account credentials from AWS Secrets Manager
# Expected JSON format: { "host": "...", "port": 5432, "username": "...", "password": "..." }
# ---------------------------------------------------------------------------
if ! CREDS_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text 2>/dev/null); then
    echo "ERROR: Failed to retrieve secret from AWS Secrets Manager: $SECRET_NAME" >&2
    exit 1
fi

if ! echo "$CREDS_JSON" | jq empty 2>/dev/null; then
    echo "ERROR: Invalid JSON received from AWS Secrets Manager" >&2
    exit 1
fi

export PGHOST=$(echo "$CREDS_JSON" | jq -r .host)
export PGPORT=$(echo "$CREDS_JSON" | jq -r .port)
export PGUSER=$(echo "$CREDS_JSON" | jq -r .username)
export PGPASSWORD=$(echo "$CREDS_JSON" | jq -r .password)

# Validate extracted credentials
if [[ -z "$PGHOST" || "$PGHOST" == "null" ]]; then
    echo "ERROR: Database host not found in credentials" >&2; exit 1
fi
if [[ -z "$PGPORT" || "$PGPORT" == "null" || ! "$PGPORT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid database port in credentials" >&2; exit 1
fi
if [[ -z "$PGUSER" || "$PGUSER" == "null" ]]; then
    echo "ERROR: Database username not found in credentials" >&2; exit 1
fi
if [[ -z "$PGPASSWORD" || "$PGPASSWORD" == "null" ]]; then
    echo "ERROR: Database password not found in credentials" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Derive PostgreSQL username from the email local-part
# Dots and hyphens become underscores; result must start with a letter
# Example: john.doe@company.com -> john_doe
# ---------------------------------------------------------------------------
DB_USER=$(echo "${BRITIVE_USER%@*}" | tr "." "_" | tr "-" "_")

if [[ ! "$DB_USER" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: Generated username contains invalid characters: $DB_USER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Generate a cryptographically secure temporary password (base64, 32 bytes)
# ---------------------------------------------------------------------------
if ! TEMP_PASSWORD=$(openssl rand -base64 32); then
    echo "ERROR: Failed to generate temporary password" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Test database connectivity before making any changes
# ---------------------------------------------------------------------------
if ! psql -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# If the user already exists, cleanly remove them before recreating:
#   1. Terminate their active sessions
#   2. Reassign any owned objects to the service account (prevents DROP failure)
#   3. Drop all remaining owned objects and privileges
#   4. Drop the role itself
# ---------------------------------------------------------------------------
USER_EXISTS=$(psql -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER';" \
    | tr -d " \t\n\r")

if [[ "$USER_EXISTS" != "0" ]]; then
    echo "User $DB_USER already exists — cleaning up before recreating..."
    psql -d "$DB_NAME" <<EOF
-- Terminate any active sessions for this user
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = '$DB_USER' AND pid <> pg_backend_pid();

-- Transfer any objects owned by the temp user to the service account,
-- then drop all remaining privileges and the role itself
REASSIGN OWNED BY "$DB_USER" TO "$PGUSER";
DROP OWNED BY "$DB_USER";
DROP ROLE "$DB_USER";
EOF
fi

# ---------------------------------------------------------------------------
# Create the temporary DBA user and grant privileges
# ---------------------------------------------------------------------------
echo "Creating DBA user: $DB_USER"
psql -d "$DB_NAME" <<EOF
CREATE ROLE "$DB_USER" LOGIN PASSWORD '$TEMP_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$DB_USER";
GRANT pg_monitor TO "$DB_USER";
GRANT pg_signal_backend TO "$DB_USER";
EOF

# ---------------------------------------------------------------------------
# Output pgAdmin / DBeaver connection JSON for the Britive access panel
# ---------------------------------------------------------------------------
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
