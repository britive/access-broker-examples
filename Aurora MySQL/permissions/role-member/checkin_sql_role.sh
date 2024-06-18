#!/bin/bash

MYSQL_USER=${user}
MYSQL_USER="${MYSQL_USER%%@*}"
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}"
MYSQL_HOST=${host}
MYSQL_URL=${dburl}
SECRET=${secret}
DATABASE_NAME="your_database_name"
TABLE_NAME=${table}
ROLE=${role}

finish () {
  exit "$1"
}

secret_value=$(aws secretsmanager get-secret-value --secret-id "$SECRET" --region us-west-2 --query 'SecretString' --output text)
db_user=$(echo "$secret_value" | jq -r '.username')
db_password=$(echo "$secret_value" | jq -r '.password')

tmp_conf=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)

cat <<EOF > "$tmp_conf".cnf
[client]
user = "$db_user"
password = "$db_password"
host = "$MYSQL_URL"
EOF

mysql \
  --defaults-extra-file="$tmp_conf".cnf \
  -e "REVOKE ${ROLE} ON ${DATABASE_NAME}.${TABLE_NAME} FROM '${MYSQL_USER}'@'${MYSQL_HOST}';" || finish 1

rm -f "$tmp_conf".cnf

echo "Permissions ${ROLE} have been revoked from user ${MYSQL_USER} on table ${TABLE_NAME} in database ${DATABASE_NAME}."

finish 0
