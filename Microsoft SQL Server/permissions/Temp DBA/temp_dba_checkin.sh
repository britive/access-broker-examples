#!/bin/bash

# Variables
SERVER_NAME="<server_name>.database.windows.net"
DATABASE_NAME="<database_name>"
ADMIN_USER="<admin_username>"
ADMIN_PASSWORD="<admin_password>"

# Check if the EMAIL environment variable is set
if [ -z "$EMAIL" ]; then
  echo "Error: The EMAIL environment variable is not set."
  exit 1
fi

# Extract the prefix from the email to determine the user
USER_TO_DELETE=$(echo $EMAIL | awk -F'@' '{print $1}')

# SQL commands to drop the user and login
SQL_COMMANDS="
DROP USER IF EXISTS [$USER_TO_DELETE];
DROP LOGIN IF EXISTS [$USER_TO_DELETE];
"

# Execute the SQL commands
sqlcmd -S $SERVER_NAME -d $DATABASE_NAME -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_COMMANDS"

echo "User $USER_TO_DELETE and associated login have been deleted."
