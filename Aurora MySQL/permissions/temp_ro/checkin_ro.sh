#!/bin/bash
#
# Britive checkin script: MySQL JIT read-only user removal
#
# Drops the user created at checkout. DROP USER also removes any grants.
#
# Expected env vars (set by Britive Resource Type / Profile):
#   user    - requesting user's email (Britive auto-populates)
#   host    - MySQL host part for 'user'@'host' (must match checkout, typically '%')
#   dburl   - RDS / Aurora endpoint hostname
#   secret  - AWS Secrets Manager secret ID holding admin {username, password}

set -u

# Sanitize MySQL username from email local part -- must match checkout logic
MYSQL_USER="${user%%@*}"
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}"
MYSQL_USER="${MYSQL_USER}_ro"   # must match checkout suffix

MYSQL_HOST="${host}"
MYSQL_URL="${dburl}"
SECRET="${secret}"

finish () {
  exit "$1"
}

secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region us-west-2 \
  --query 'SecretString' \
  --output text) || finish 1

db_user=$(echo "$secret_value" | jq -r '.username')
db_password=$(echo "$secret_value" | jq -r '.password')

export MYSQL_PWD="$db_password"
trap 'unset MYSQL_PWD' EXIT

mysql -h "$MYSQL_URL" -u "$db_user" \
  -e "DROP USER IF EXISTS '${MYSQL_USER}'@'${MYSQL_HOST}';" \
  || finish 1

finish 0