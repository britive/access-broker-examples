#!/bin/bash

# Variables
SERVER_NAME=$server_name
DATABASE_NAME=$database_name
ADMIN_USER=$admin_user
ADMIN_PASSWORD=$admin_password
EMAIL=$user_email

# Check if the EMAIL environment variable is set
if [ -z "$EMAIL" ]; then
  echo "Error: The EMAIL environment variable is not set."
  exit 1
fi

# Extract the prefix from the email to determine the user
USER_TO_DELETE=$(echo $EMAIL | awk -F'@' '{print $1}')

# SQL commands to drop the user from the database
SQL_COMMANDS_DATABASE="
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$USER_TO_DELETE')
BEGIN
    DROP USER [$USER_TO_DELETE];
END
"

# SQL commands to drop the login from the master database
SQL_COMMANDS_MASTER="
DROP LOGIN [$USER_TO_DELETE];
"

# Step 1: SQL command to find all session IDs (SPIDs) for the login
SQL_FIND_SESSIONS="SELECT session_id FROM sys.dm_exec_sessions WHERE login_name = '$USER_TO_DELETE';"

# Execute the SQL command to find session IDs and store them in a variable
SESSION_IDS=$(sqlcmd -S $SERVER_NAME -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_FIND_SESSIONS" -h -1 -W | grep -E '^[0-9]+$')

# Step 2: Loop through each session ID and kill it
for SESSION_ID in $SESSION_IDS; do
    echo "Killing session ID: $SESSION_ID"
    SQL_KILL_SESSION="KILL $SESSION_ID;"
    sqlcmd -S $SERVER_NAME -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_KILL_SESSION"
done


# Execute the SQL commands to drop the user from the target database
sqlcmd -S $SERVER_NAME -d $DATABASE_NAME -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_COMMANDS_DATABASE"

# Execute the SQL commands to drop the login from the master database
sqlcmd -S $SERVER_NAME -d master -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_COMMANDS_MASTER"

echo "User $USER_TO_DELETE and associated login have been deleted."