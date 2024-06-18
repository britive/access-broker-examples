#!/bin/bash

# Database Environment Variables
DB_HOST="your-db-host"
DB_PORT="1521"
DB_SERVICE_NAME="your-db-service"
DB_USER="your-username"
DB_PASS="your-password"
USERNAME=$user


echo "Revoking DBA role from user $USERNAME..."

# Execute SQL command to revoke DBA role
sqlplus -s "$DB_USER/$DB_PASS@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$DB_HOST)(PORT=$DB_PORT))(CONNECT_DATA=(SERVICE_NAME=$DB_SERVICE_NAME)))" <<EOF
REVOKE DBA FROM $USERNAME;
EXIT;
EOF

if [ $? -eq 0 ]; then
    echo "DBA role revoked from user $USERNAME successfully."
else
    echo "Failed to revoke DBA role from user $USERNAME."
    exit 1
fi
