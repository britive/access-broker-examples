#!/bin/bash
#
# Britive checkout script: Aurora MySQL JIT user creation
#
# Expected env vars (set by Britive Resource Type / Profile):
#   user    - requesting user's email (Britive auto-populates)
#   host    - MySQL host part for 'user'@'host' (typically '%')
#   dburl   - RDS / Aurora endpoint hostname
#   secret  - AWS Secrets Manager secret ID holding admin {username, password}

set -u

# Sanitize MySQL username from email local part
MYSQL_USER="${user%%@*}"
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}"

MYSQL_HOST="${host}"
MYSQL_URL="${dburl}"
SECRET="${secret}"

# Create temp config file with restrictive perms BEFORE writing credentials
tmp_conf=$(mktemp --suffix=.cnf) || exit 1
chmod 600 "$tmp_conf"
trap 'rm -f "$tmp_conf"' EXIT

finish () {
  exit "$1"
}

# Generate a random password for the new MySQL user
password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

# Fetch admin creds from Secrets Manager
secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region us-west-2 \
  --query 'SecretString' \
  --output text) || finish 1

db_user=$(echo "$secret_value" | jq -r '.username')
db_password=$(echo "$secret_value" | jq -r '.password')

# Note: no quotes around values in [client] section -- mysql treats them literally
cat > "$tmp_conf" <<EOF
[client]
user = $db_user
password = $db_password
host = $MYSQL_URL
EOF

mysql --defaults-extra-file="$tmp_conf" \
  -e "CREATE USER '${MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED BY '${password}';" \
  || finish 1

mysql --defaults-extra-file="$tmp_conf" \
  -e "GRANT ALL ON systemdb.* TO '${MYSQL_USER}'@'${MYSQL_HOST}';" \
  || finish 1

# Output connection command for the user
echo "mysql -h${MYSQL_URL} -u${MYSQL_USER} -p\"${password}\""

finish 0