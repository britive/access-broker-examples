#!/bin/bash
#
# Britive checkout script: Aurora MySQL JIT user + Bridge proxied session
#
# Creates a temporary MySQL user with a random password, then registers a
# database checkout with the Britive Bridge so the user connects through the
# Bridge proxy using a per-checkout Bridge password. The real MySQL
# credentials never leave the broker/Bridge.
#
# Required env vars (set by Britive Resource Type / Profile):
#   user        - requesting user's email (Britive auto-populates)
#   host        - MySQL host part for 'user'@'host' (typically '%')
#   dburl       - RDS / Aurora endpoint hostname
#   secret      - AWS Secrets Manager secret ID holding admin {username, password}
#   TRX         - Britive transaction ID
#   BRIDGE_URL  - Public Bridge base URL (e.g. https://bridge.example.com)
#   EXPIRATION  - Checkout duration in seconds
#
# Optional env vars (with defaults):
#   DB_NAME     - Database the grant applies to (default: systemdb)
#   DB_PORT     - MySQL port on the target (default: 3306)
#   NATIVE_PORT - Bridge native MySQL listener port (default: 3306)
#   NATIVE_AUTH - bridge_credentials (default) or ldap
#   TARGET_TLS  - true/false, TLS from Bridge to Aurora (default: true)
#   DB_CA_CERT  - path to the RDS CA bundle on the broker; enables server cert
#                 verification for the admin connection. Without it the
#                 connection is encrypted but the chain is not verified.
#                 Download: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   BROKER_API  - Path to broker-bridge-api.sh (default: /opt/britive-broker/scripts/broker-bridge-api.sh)

set -u

# Sanitize MySQL username from email local part
USER_EMAIL="${user}"
MYSQL_USER="${USER_EMAIL%%@*}"
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}"

MYSQL_HOST="${host}"
MYSQL_URL="${dburl}"
SECRET="${secret}"
TRANSACTION_ID="${TRX}"
DB_NAME="${DB_NAME:-systemdb}"
DB_PORT="${DB_PORT:-3306}"
NATIVE_PORT="${NATIVE_PORT:-3306}"
NATIVE_AUTH="${NATIVE_AUTH:-bridge_credentials}"
TARGET_TLS="${TARGET_TLS:-true}"
DB_CA_CERT="${DB_CA_CERT:-}"
AWS_REGION="${AWS_REGION:-us-west-2}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

require_var() {
  var_name="$1"
  eval "var_value=\${$1:-}"
  if [ -z "$var_value" ]; then
    echo "error: required env var missing: $var_name" >&2
    exit 1
  fi
}

require_var user
require_var host
require_var dburl
require_var secret
require_var TRX
require_var BRIDGE_URL
require_var EXPIRATION

# Create temp files with restrictive perms BEFORE writing credentials
tmp_conf=$(mktemp --suffix=.cnf) || exit 1
payload=$(mktemp --suffix=.json) || exit 1
chmod 600 "$tmp_conf" "$payload"
trap 'rm -f "$tmp_conf" "$payload"' EXIT

finish () {
  exit "$1"
}

# Random password for the temp MySQL user -- only the Bridge ever sees it
db_user_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

# Fetch admin creds from Secrets Manager
secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text) || finish 1

db_admin_user=$(echo "$secret_value" | jq -r '.username')
db_admin_password=$(echo "$secret_value" | jq -r '.password')

# Note: no quotes around values in [client] section -- mysql treats them literally
cat > "$tmp_conf" <<EOF
[client]
user = $db_admin_user
password = $db_admin_password
host = $MYSQL_URL
EOF

# TLS to Aurora: newer MariaDB clients verify the server cert by default and
# reject the RDS CA ("self-signed certificate in certificate chain"). Verify
# against DB_CA_CERT when provided; otherwise keep the connection encrypted
# but skip chain verification. Option names differ per client flavor.
if mysql --version 2>/dev/null | grep -qi mariadb; then
  if [ -n "$DB_CA_CERT" ]; then
    printf 'ssl-ca = %s\nssl-verify-server-cert = 1\n' "$DB_CA_CERT" >> "$tmp_conf"
  else
    printf 'ssl-verify-server-cert = 0\n' >> "$tmp_conf"
  fi
else
  if [ -n "$DB_CA_CERT" ]; then
    printf 'ssl-ca = %s\nssl-mode = VERIFY_CA\n' "$DB_CA_CERT" >> "$tmp_conf"
  else
    printf 'ssl-mode = REQUIRED\n' >> "$tmp_conf"
  fi
fi

mysql --defaults-extra-file="$tmp_conf" \
  -e "CREATE USER '${MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED BY '${db_user_password}';" \
  || finish 1

mysql --defaults-extra-file="$tmp_conf" \
  -e "GRANT ALL ON ${DB_NAME}.* TO '${MYSQL_USER}'@'${MYSQL_HOST}';" \
  || finish 1

# Drop the temp user again if Bridge registration fails
rollback() {
  mysql --defaults-extra-file="$tmp_conf" \
    -e "DROP USER IF EXISTS '${MYSQL_USER}'@'${MYSQL_HOST}';" >/dev/null 2>&1
}

# ==============================
# Register the Bridge checkout
# ==============================
TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)
EXPIRES_AT=$(($(date +%s) + EXPIRATION))

# bridge_credentials: user authenticates to the Bridge proxy with a
# per-checkout password generated here. ldap: user authenticates with
# their own directory password; no password is generated.
if [ "$NATIVE_AUTH" = "bridge_credentials" ]; then
  BRIDGE_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
  AUTH_FIELDS="\"native_auth\": \"bridge_credentials\",
  \"bridge_auth_password\": \"${BRIDGE_PASSWORD}\","
else
  BRIDGE_PASSWORD=""
  AUTH_FIELDS="\"native_auth\": \"${NATIVE_AUTH}\","
fi

cat > "$payload" <<EOF
{
  "transaction_id": "${TRANSACTION_ID}",
  "protocol": "mysql",
  "username": "${USER_EMAIL}",
  "target_host": "${MYSQL_URL}",
  "target_port": ${DB_PORT},
  "target_username": "${MYSQL_USER}",
  "target_password": "${db_user_password}",
  "target_database": "${DB_NAME}",
  "target_tls": ${TARGET_TLS},
  ${AUTH_FIELDS}
  "expires_at": ${EXPIRES_AT},
  "token": "${TOKEN}"
}
EOF

if ! "${BROKER_API}" checkout-create --file "$payload" >/dev/null; then
  rollback
  finish 1
fi

# ==============================
# Output connection details
# ==============================
# Native clients connect to the Bridge host with username <bridge-user>%<target-host>
BRIDGE_HOST="${BRIDGE_URL#https://}"
BRIDGE_HOST="${BRIDGE_HOST#http://}"
BRIDGE_HOST="${BRIDGE_HOST%%[:/]*}"
NATIVE_USER="${USER_EMAIL}%${MYSQL_URL}"
MYSQL_CMD="mysql -h ${BRIDGE_HOST} -P ${NATIVE_PORT} -u '${NATIVE_USER}' -p ${DB_NAME}"
URL="${BRIDGE_URL}/connect?transaction_id=${TRANSACTION_ID}"

jq -n \
  --arg token "$TOKEN" \
  --arg url "$URL" \
  --arg mysql_command "$MYSQL_CMD" \
  --arg bridge_username "$NATIVE_USER" \
  --arg bridge_password "$BRIDGE_PASSWORD" \
  --arg bridge_host "$BRIDGE_HOST" \
  --arg bridge_port "$NATIVE_PORT" \
  '{token: $token, url: $url, mysql_command: $mysql_command,
    bridge_username: $bridge_username, bridge_password: $bridge_password,
    bridge_host: $bridge_host, bridge_port: $bridge_port}'

finish 0
