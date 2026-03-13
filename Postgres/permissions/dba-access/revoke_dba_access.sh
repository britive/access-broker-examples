#!/bin/bash

# PostgreSQL DBA Access Revoke Script
# Purpose: Revokes DBA privileges and removes the temporary PostgreSQL user
# Usage: BRITIVE_USER=<email> SECRET_NAME=<secret> DB_NAME=<database> ./revoke_dba_access.sh

# Enable strict error handling: exit on error, unset var, or pipe failure
set -euo pipefail

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
for tool in aws jq psql; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool not found: $tool" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Retrieve service account credentials from AWS Secrets Manager
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
# Example: john.doe@company.com -> john_doe
# ---------------------------------------------------------------------------
DB_USER=$(echo "${BRITIVE_USER%@*}" | tr "." "_" | tr "-" "_")

if [[ ! "$DB_USER" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: Generated username contains invalid characters: $DB_USER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Test database connectivity before making any changes
# ---------------------------------------------------------------------------
if ! psql -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to database $DB_NAME" >&2
    exit 1
fi

echo "Revoking DBA access and deleting user $BRITIVE_USER ($DB_USER) on $DB_NAME..."

# ---------------------------------------------------------------------------
# Check if the user exists; exit cleanly if already gone (idempotent)
# ---------------------------------------------------------------------------
USER_EXISTS=$(psql -d "$DB_NAME" -t -c \
    "SELECT COUNT(*) FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER';" \
    | tr -d " \t\n\r")

if [[ "$USER_EXISTS" == "0" ]]; then
    echo "User $DB_USER was not found (already removed or never existed)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Remove the user:
#   1. Terminate active sessions (cannot drop a role with open connections)
#   2. Reassign owned objects to the service account (prevents DROP failure
#      if the user created schemas, tables, or sequences during their session)
#   3. Drop all remaining privileges and objects
#   4. Drop the role
# ---------------------------------------------------------------------------
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

echo "Access revoked and user $DB_USER deleted."
