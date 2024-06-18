#!/bin/bash

PS_USER=${user}
PS_USER="${PS_USER%%@*}"
PS_USER="${PS_USER//[^a-zA-Z0-9]/}"

SVC_USER=${svc_user}
SVC_PASS=${svc_password}
DB_HOST=${host}
DB_NAME=${db_name}

finish () {
  exit "$1"
}

# Revoke privileges from the user (if any were granted)
PGPASSWORD=$SVC_PASS psql -p 5432 -h $DB_HOST -U $SVC_USER -d $DB_NAME -c "REVOKE ALL PRIVILEGES ON DATABASE $DB_NAME FROM $PS_USER;"

# Drop the user
PGPASSWORD=$SVC_PASS psql -p 5432 -h $DB_HOST -U $SVC_USER -d $DB_NAME -c "DROP USER $PS_USER;"

echo "User $PS_USER has been dropped."

finish 0
