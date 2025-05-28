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
DB_USER="${USER_EMAIL%@*}"  # strips domain
TEMP_PASSWORD=$(openssl rand -base64 16)

# echo "Granting DBA access to $USER_EMAIL ($DB_USER) on $DB_NAME..."
# echo "Temporary password: $TEMP_PASSWORD"

psql -d "$DB_NAME" <<EOF
DO \$\$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}'
   ) THEN
      CREATE ROLE ${DB_USER} LOGIN PASSWORD '${TEMP_PASSWORD}';
   END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
GRANT pg_monitor TO ${DB_USER};
GRANT pg_signal_backend TO ${DB_USER};
EOF

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