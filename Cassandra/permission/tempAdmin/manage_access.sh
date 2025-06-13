#!/bin/bash

set -e

# ---------------------------
# Parse command-line arguments
# ---------------------------
EMAIL=$BRITIVE_EMAIL
PASSWORD=$SECRET
PERMISSIONS=$BRITIVE_PERMISSION
ACTION=$BRITIVE_ACTION
HOST=$BRITIVE_CASSANDRA_HOST

# ---------------------------
# Validate required input
# ---------------------------
if [[ -z "$EMAIL" || -z "$ACTION" ]]; then
  echo "❌ --username and --action are required."
  usage
fi

# ---------------------------
# Strip domain from email to get Cassandra username
# e.g., alice@example.com → alice
# ---------------------------
USERNAME=$(echo "$EMAIL" | cut -d'@' -f1)

# ---------------------------
# Load Cassandra admin credentials from AWS Secrets Manager
# Alternatively, you can pass these attributes from the 
# Britive platform along with other parameters
# ---------------------------
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id cassandra/admin/password \
  --query SecretString --output text)

ADMIN_USER=$(echo "$SECRET_JSON" | jq -r .username)
ADMIN_PASS=$(echo "$SECRET_JSON" | jq -r .password)

# ---------------------------
# Cassandra host (override with CASSANDRA_HOST env var if needed)
# ---------------------------
CASSANDRA_HOST=${HOST:-localhost}

# ---------------------------
# Helper: run a CQL query with admin credentials
# ---------------------------
function run_cql() {
  echo "$1" | cqlsh "$CASSANDRA_HOST" -u "$ADMIN_USER" -p "$ADMIN_PASS"
}

# ---------------------------
# ADD action: create user and grant permissions
# ---------------------------
if [[ "$ACTION" == "checkout" ]]; then
  if [[ -z "$PASSWORD" || -z "$PERMISSIONS" ]]; then
    echo "❌ Both --password and --permissions are required when using --action add."
    exit 1
  fi

  echo "🔐 Creating user '$USERNAME' and granting permissions: $PERMISSIONS"

  run_cql "CREATE USER IF NOT EXISTS $USERNAME WITH PASSWORD '$PASSWORD' NOSUPERUSER;"

  for PERM in $PERMISSIONS; do
    run_cql "GRANT $PERM ON ALL KEYSPACES TO $USERNAME;"
  done

  echo "✅ User '$USERNAME' created and permissions granted."

# ---------------------------
# REMOVE action: revoke permissions and drop user
# ---------------------------
elif [[ "$ACTION" == "checkin" ]]; then

  # List of common permissions to revoke
  for PERM in SELECT MODIFY CREATE ALTER DROP AUTHORIZE; do
    run_cql "REVOKE $PERM ON ALL KEYSPACES FROM $USERNAME;" || true
  done

  run_cql "DROP USER IF EXISTS $USERNAME;"
  echo "✅ User '$USERNAME' revoked and removed."

