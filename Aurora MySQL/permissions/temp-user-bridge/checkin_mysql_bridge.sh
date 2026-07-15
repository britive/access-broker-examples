#!/bin/bash
#
# Britive checkin script: Aurora MySQL JIT user removal + Bridge session teardown
#
# Drops the temporary MySQL user created at checkout and deletes the Bridge
# checkout, which immediately terminates any active proxied session.
#
# Required env vars (set by Britive Resource Type / Profile):
#   user    - requesting user's email (Britive auto-populates)
#   host    - MySQL host part for 'user'@'host' (must match checkout, typically '%')
#   dburl   - RDS / Aurora endpoint hostname
#   secret  - AWS Secrets Manager secret ID holding admin {username, password}
#   TRX     - Britive transaction ID (matches the checkout TRX)
#
# Optional env vars (with defaults):
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   BROKER_API  - Path to broker-bridge-api.sh (default: /opt/britive-broker/scripts/broker-bridge-api.sh)

set -u

# Sanitize MySQL username from email local part -- must match checkout logic
MYSQL_USER="${user%%@*}"
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}"

MYSQL_HOST="${host}"
MYSQL_URL="${dburl}"
SECRET="${secret}"
TRANSACTION_ID="${TRX}"
AWS_REGION="${AWS_REGION:-us-west-2}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

tmp_conf=$(mktemp --suffix=.cnf) || exit 1
chmod 600 "$tmp_conf"
trap 'rm -f "$tmp_conf"' EXIT

finish () {
  exit "$1"
}

rc=0

secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text) || finish 1

db_admin_user=$(echo "$secret_value" | jq -r '.username')
db_admin_password=$(echo "$secret_value" | jq -r '.password')

cat > "$tmp_conf" <<EOF
[client]
user = $db_admin_user
password = $db_admin_password
host = $MYSQL_URL
EOF

mysql --defaults-extra-file="$tmp_conf" \
  -e "DROP USER IF EXISTS '${MYSQL_USER}'@'${MYSQL_HOST}';" \
  || rc=1

# Delete the Bridge checkout -- revokes the proxy credential and
# terminates any active session immediately
"${BROKER_API}" checkout-delete "${TRANSACTION_ID}" || rc=1

finish "$rc"
