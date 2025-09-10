#!/bin/bash

# Aurora MySQL Role Checkin Script
# Revokes role permissions from a temporary MySQL user

# Input validation - check required environment variables
if [[ -z "$user" || -z "$host" || -z "$dburl" || -z "$secret" || -z "$table" || -z "$role" ]]; then
    echo "Error: Missing required environment variables. Please set: user, host, dburl, secret, table, role" >&2
    exit 1
fi

# Extract and sanitize username (remove domain part and special characters)
MYSQL_USER=${user}
MYSQL_USER="${MYSQL_USER%%@*}"  # Remove everything after @
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}"  # Keep only alphanumeric characters

# Set connection parameters
MYSQL_HOST=${host}
MYSQL_URL=${dburl}
SECRET=${secret}

# TODO: Update this to your actual database name
DATABASE_NAME=${database_name}
TABLE_NAME=${table}
ROLE=${role}

# AWS region for Secrets Manager (modify if using different region)
AWS_REGION=${AWS_REGION:-"us-west-2"}

# Exit function with cleanup
finish () {
  # Clean up temporary files if they exist
  [[ -n "$tmp_conf" && -f "$tmp_conf.cnf" ]] && rm -f "$tmp_conf.cnf"
  exit "$1"
}

# Retrieve database admin credentials from AWS Secrets Manager
echo "Retrieving database credentials from Secrets Manager..." >&2
secret_value=$(aws secretsmanager get-secret-value --secret-id "$SECRET" --region "$AWS_REGION" --query 'SecretString' --output text)
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to retrieve secret from AWS Secrets Manager" >&2
    finish 1
fi

# Parse JSON credentials
db_user=$(echo "$secret_value" | jq -r '.username')
db_password=$(echo "$secret_value" | jq -r '.password')

if [[ "$db_user" == "null" || "$db_password" == "null" ]]; then
    echo "Error: Invalid credentials format in secret" >&2
    finish 1
fi

# Generate temporary config file name
tmp_conf=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)

# Create MySQL configuration file with admin credentials
echo "Creating MySQL configuration..." >&2
cat <<EOF > "$tmp_conf".cnf
[client]
user = "$db_user"
password = "$db_password"
host = "$MYSQL_URL"
EOF

# Revoke role permissions from the user
echo "Revoking ${ROLE} permissions from ${MYSQL_USER}@${MYSQL_HOST} on ${DATABASE_NAME}.${TABLE_NAME}" >&2
mysql \
  --defaults-extra-file="$tmp_conf".cnf \
  -e "REVOKE ${ROLE} ON ${DATABASE_NAME}.${TABLE_NAME} FROM '${MYSQL_USER}'@'${MYSQL_HOST}';"

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to revoke permissions from user ${MYSQL_USER}" >&2
    finish 1
fi

# Clean up configuration file
rm -f "$tmp_conf".cnf

echo "Permissions ${ROLE} have been revoked from user ${MYSQL_USER} on table ${TABLE_NAME} in database ${DATABASE_NAME}."

finish 0
