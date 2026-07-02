#!/bin/bash
#
# Britive checkout script: MySQL JIT read-only user creation
#
# Creates a database user (if not exists) with read-only access.
# Read-only = SELECT on all databases + SHOW VIEW (for inspecting view defs).
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
MYSQL_USER="${MYSQL_USER}_ro"   # suffix to avoid collision with R/W users

MYSQL_HOST="${host}"
MYSQL_URL="${dburl}"
SECRET="${secret}"

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

# Use MYSQL_PWD -- avoids cnf parsing issues with special chars (#, ;, etc.)
export MYSQL_PWD="$db_password"
trap 'unset MYSQL_PWD' EXIT

# CREATE USER IF NOT EXISTS keeps the script idempotent across repeat checkouts.
# ALTER USER ... IDENTIFIED BY rotates the password every checkout regardless,
# so a previous session's password stops working as soon as a new checkout runs.
mysql -h "$MYSQL_URL" -u "$db_user" \
  -e "CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED BY '${password}';
      ALTER USER '${MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED BY '${password}';" \
  || finish 1

# Grant read-only on all databases.
# SELECT       -- read rows
# SHOW VIEW    -- inspect view definitions
# PROCESS      -- optional: see SHOW PROCESSLIST (omit if not desired)
mysql -h "$MYSQL_URL" -u "$db_user" \
  -e "GRANT SELECT, SHOW VIEW ON *.* TO '${MYSQL_USER}'@'${MYSQL_HOST}';
      FLUSH PRIVILEGES;" \
  || finish 1

# Output user-facing connection command (single line, ready to copy/paste).
echo "mysql -h${MYSQL_URL} -u${MYSQL_USER} -p\"${password}\""

finish 0