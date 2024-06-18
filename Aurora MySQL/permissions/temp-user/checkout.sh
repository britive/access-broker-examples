#!/bin/bash

MYSQL_USER=${user}
MYSQL_USER="${MYSQL_USER%%@*}"
MYSQL_USER="${MYSQL_USER//[^a-zA-Z0-9]/}"
MYSQL_HOST=${host}
MYSQL_URL=${dburl}
SECRET=${secret}

finish () {
  exit "$1"
}

password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

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
  -e "CREATE USER '${MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED BY '${password}';" || finish 1

mysql \
  --defaults-extra-file="$tmp_conf".cnf \
  -e "GRANT ALL ON systemdb.* TO '${MYSQL_USER}'@'${MYSQL_HOST}';" || finish 1

rm -f "$tmp_conf".cnf

echo "$MYSQL_USER"
echo "$password"
echo "mysql -h$MYSQL_URL -u$MYSQL_USER -p\"$password\""

finish 0
