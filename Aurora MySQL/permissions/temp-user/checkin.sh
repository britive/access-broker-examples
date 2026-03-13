#!/bin/bash

# Aurora MySQL Temporary User Checkin Script
# Drops the temporary MySQL user and revokes all access

# Input validation - check required environment variables
if [[ -z "$user" || -z "$host" || -z "$dburl" || -z "$secret" ]]; then
    echo "Error: Missing required environment variables. Please set: user, host, dburl, secret" >&2
    exit 1
fi

# Extract and sanitize username (remove domain part and special characters)
MYSQL_USER=${user}
MYSQL_USER="${MYSQL_USER%%@*}"             # Remove everything after @
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}" # Keep only alphanumeric characters

# Set connection parameters
MYSQL_HOST=${host}
MYSQL_URL=${dburl}
SECRET=${secret}

# AWS region for Secrets Manager (override with AWS_REGION env var if needed)
AWS_REGION=${AWS_REGION:-"us-west-2"}

# Exit function with cleanup of temporary credential file
finish () {
  [[ -n "$tmp_conf" && -f "$tmp_conf.cnf" ]] && rm -f "$tmp_conf.cnf"
  exit "$1"
}

# Retrieve database admin credentials from AWS Secrets Manager
echo "Retrieving database credentials from Secrets Manager..." >&2
secret_value=$(aws secretsmanager get-secret-value --secret-id "$SECRET" --region "$AWS_REGION" --query 'SecretString' --output text)
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to retrieve secret from AWS Secrets Manager" >&2
    exit 1
fi

# Parse JSON credentials
db_user=$(echo "$secret_value" | jq -r '.username')
db_password=$(echo "$secret_value" | jq -r '.password')

if [[ "$db_user" == "null" || "$db_password" == "null" ]]; then
    echo "Error: Invalid credentials format in secret. Expected keys: username, password" >&2
    exit 1
fi

# Generate temporary config file name (random to avoid collisions)
tmp_conf=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)

# Create MySQL configuration file with admin credentials
cat <<EOF > "$tmp_conf.cnf"
[client]
user = "$db_user"
password = "$db_password"
host = "$MYSQL_URL"
EOF

# Drop the temporary MySQL user
echo "Dropping MySQL user: ${MYSQL_USER}@${MYSQL_HOST}" >&2
mysql \
  --defaults-extra-file="$tmp_conf.cnf" \
  -e "DROP USER IF EXISTS '${MYSQL_USER}'@'${MYSQL_HOST}';"

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to drop MySQL user ${MYSQL_USER}" >&2
    finish 1
fi

echo "User ${MYSQL_USER} successfully removed." >&2

finish 0
