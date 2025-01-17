#!/bin/bash

# Variables
SERVER_NAME=$server_name
DATABASE_NAME=$database_name
ADMIN_USER=$admin_user
ADMIN_PASSWORD=$admin_password
EMAIL=$user_email

# Function to generate a random 9-character password
generate_password() {
  openssl rand -base64 12 | tr -dc 'A-Za-z0-9@#$%^&+=_' | head -c 12
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

echo "New User Password: $NEW_USER_PASSWORD"

# SQL commands to create a new login and user with full admin privileges
SQL_COMMANDS_MASTER="
CREATE LOGIN [$NEW_USER] WITH PASSWORD = '$NEW_USER_PASSWORD';
"

SQL_COMMANDS_DATABASE="
CREATE USER [$NEW_USER] FOR LOGIN [$NEW_USER] WITH DEFAULT_SCHEMA=[db_owner];
ALTER ROLE db_owner ADD MEMBER [$NEW_USER];
"

# Execute the SQL commands in the master database to create the login
sqlcmd -S $SERVER_NAME -d master -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_COMMANDS_MASTER"

# Execute the SQL commands in the target database to create the user
sqlcmd -S $SERVER_NAME -d $DATABASE_NAME -U $ADMIN_USER -P $ADMIN_PASSWORD -Q "$SQL_COMMANDS_DATABASE"

# Output the connection string for the new user
echo "Connection string for the new user:"
echo "Server=$SERVER_NAME;Database=$DATABASE_NAME;User Id=$NEW_USER;Password=$NEW_USER_PASSWORD;"