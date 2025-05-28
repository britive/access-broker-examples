#!/bin/bash
set -e

# --- Get DB credentials from AWS Secrets Manager ---
if [[ -z "$SECRET_NAME" ]]; then
  echo "SECRET_NAME environment variable is not set"
  exit 1
fi

CREDS_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text)

export PGHOST=$(echo "$CREDS_JSON" | jq -r .host)
export PGPORT=$(echo "$CREDS_JSON" | jq -r .port)
export PGUSER=$(echo "$CREDS_JSON" | jq -r .username)
export PGPASSWORD=$(echo "$CREDS_JSON" | jq -r .password)

# --- Prepare variables ---
DB_USER=$(echo "$USER_EMAIL" | tr '@.' '__')

echo "Revoking DBA access and deleting user $USER_EMAIL ($DB_USER) on $DB_NAME..."

psql -d "$DB_NAME" <<EOF
REVOKE ALL PRIVILEGES ON DATABASE ${DB_NAME} FROM ${DB_USER};
REVOKE pg_monitor FROM ${DB_USER};
REVOKE pg_signal_backend FROM ${DB_USER};
DROP ROLE IF EXISTS ${DB_USER};
EOF

echo "✅ Access revoked and user $DB_USER deleted."
