#!/bin/bash

# Database Environment Variables
DB_HOST="your-db-host"
DB_PORT="1521"
DB_SERVICE_NAME="your-db-service"
DB_USER="your-username"
DB_PASS="your-password"
USERNAME=$user
TABLE_NAME=$table


echo "Revoking read-only access on table $TABLE_NAME from user $USERNAME..."

# Execute SQL command to revoke SELECT privilege
sqlplus -s "$DB_USER/$DB_PASS@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$DB_HOST)(PORT=$DB_PORT))(CONNECT_DATA=(SERVICE_NAME=$DB_SERVICE_NAME)))" <<EOF
REVOKE SELECT ON $TABLE_NAME FROM $USERNAME;
EXIT;
EOF

if [ $? -eq 0 ]; then
    echo "Read-only access revoked on table $TABLE_NAME from user $USERNAME successfully."
else
    echo "Failed to revoke read-only access on table $TABLE_NAME from user $USERNAME."
    exit 1
fi
