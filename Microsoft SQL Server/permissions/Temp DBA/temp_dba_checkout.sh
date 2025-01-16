#!/bin/bash

# Variables
SERVER_NAME="<server_name>.database.windows.net"
DATABASE_NAME="<database_name>"
ADMIN_USER="<admin_username>"
ADMIN_PASSWORD="<admin_password>"

# Function to generate a random 9-character password
generate_password() {
  tr -dc 'A-Za-z0-9@#$%^&+=_' </dev/urandom | head -c 9
}

# Check if the EMAIL environment variable is set
if [ -z "$EMAIL" ]; then
  echo "Error: The EMAIL environment variable is not set."
  exit 1
fi

# Extract the prefix from the email
NEW_USER=$(echo $EMAIL | awk -F'@' '{print $1}')

# Generate a random 9-character password
NEW_USER_PASSWORD=$(generate_password)

# SQL commands to create a new user with full admin privileges
SQL_COMMANDS="
CREATE LOGIN [$NEW_USER] WITH PASSWORD = '$NEW_USER_PASSWORD';
CREATE USER [$NEW_USER] FOR LOGIN [$NEW_USER];
EXEC sp_addrolemember 'db_owner', '$NEW_USER';
"

# Execute the SQL commands
sqlcmd -S $SERVER_NAME -d $DATABASE_NAME -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_COMMANDS"

# Output the connection string for the new user
echo "Connection string for the new user:"
echo "Server=$SERVER_NAME;Database=$DATABASE_NAME;User Id=$NEW_USER;Password=$NEW_USER_PASSWORD;"
