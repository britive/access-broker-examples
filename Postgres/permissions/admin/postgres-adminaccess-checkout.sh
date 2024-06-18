#!/bin/bash

PS_USER=${user}
PS_USER="${PS_USER%%@*}"
PS_USER="${PS_USER//[^a-zA-Z0-9]/}"

SVC_USER=${svc_user}
SVC_PASS=${svc_password}
DB_HOST=${db_host}
DB_NAME=${db_name}

PS_PASS=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 10)

# tmp_conf=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)

# Create a new PostgreSQL user
export PGPASSWORD=${SVC_PASS}
psql -U ${SVC_USER} -p 5432 -h ${DB_HOST} -d ${DB_NAME} -c "CREATE USER ${PS_USER} WITH PASSWORD '${PS_PASS}';"


# Grant all privileges on the database to the user
psql -U ${SVC_USER} -p 5432 -h ${DB_HOST} -d ${DB_NAME} -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${PS_USER};"


echo "User $PS_USER created and granted admin privileges on $DB_NAME."
echo "PGPASSWORD=$PS_PASS psql -p 5432 -h $DB_HOST -U $PS_USER -d $DB_NAME"