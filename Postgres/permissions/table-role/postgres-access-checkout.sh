#!/bin/bash

PS_USER=${user}
PS_USER="${PS_USER%%@*}"
PS_USER="${PS_USER//[^a-zA-Z0-9]/}"

SVC_USER=${svc_user}
SVC_PASS=${svc_password}
DB_HOST=${db_host}
DB_NAME=${db_name}
ROLE_NAME=${role_name}


# Grant a role to a user
export PGPASSWORD=${SVC_PASS}
psql -h $DB_HOST -p 5432 -U $SVC_USER -d $DB_NAME -c "GRANT $ROLE_NAME TO $PS_USER;"

# Check if the role was successfully granted
if [ $? -eq 0 ]; then
    echo "Role $ROLE_NAME successfully granted to user $USER_NAME."
else
    echo "Failed to grant role $ROLE_NAME to user $USER_NAME."
fi
