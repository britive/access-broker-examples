#!/bin/bash

# Exit on any error
set -e

# Variables
SERVER_NAME=$server_name
DATABASE_NAME=$database_name
ADMIN_USER=$admin_user
ADMIN_PASSWORD=$admin_password
EMAIL=$user_email

# Error handling function
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Function to sanitize username by removing special characters
# Keeps only alphanumeric characters, underscores, and hyphens
sanitize_username() {
    local username=$1
    # Remove all characters except alphanumeric, underscore, and hyphen
    local sanitized=$(echo "$username" | tr -dc 'A-Za-z0-9_-')

    # Remove leading numbers (SQL Server requirement - identifiers can't start with numbers)
    sanitized=$(echo "$sanitized" | sed 's/^[0-9]*//')

    # Ensure username is not empty after sanitization
    if [ -z "$sanitized" ]; then
        error_exit "Username became empty after sanitization. Original: $username"
    fi

    # Ensure username is not too long (SQL Server max is 128 characters)
    if [ ${#sanitized} -gt 128 ]; then
        sanitized="${sanitized:0:128}"
    fi

    echo "$sanitized"
}

# Function to generate a random 12-character password
generate_password() {
    openssl rand -base64 12 | tr -dc 'A-Za-z0-9@#$%^&+=_' | head -c 12
}

# Validate required environment variables
for var in EMAIL SERVER_NAME DATABASE_NAME ADMIN_USER ADMIN_PASSWORD; do
    if [ -z "${!var}" ]; then
        error_exit "The $var environment variable is not set."
    fi
done

# Extract the prefix from the email
EMAIL_PREFIX=$(echo "$EMAIL" | awk -F'@' '{print $1}')

if [ -z "$EMAIL_PREFIX" ]; then
    error_exit "Failed to extract username from email: $EMAIL"
fi

# Sanitize the username
NEW_USER=$(sanitize_username "$EMAIL_PREFIX")

# Generate a random 12-character password
NEW_USER_PASSWORD=$(generate_password)

if [ -z "$NEW_USER_PASSWORD" ]; then
    error_exit "Failed to generate password"
fi

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

if ! /opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -d master -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$SQL_COMMANDS_MASTER" -C; then
    error_exit "Failed to create login [$NEW_USER] in master database"
fi

# Execute the SQL commands in the target database to create the user

if ! /opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -d "$DATABASE_NAME" -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$SQL_COMMANDS_DATABASE" -C; then
    # Attempt to rollback by dropping the login
    echo "Failed to create user. Attempting to rollback by dropping login..."
    /opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -d master -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "DROP LOGIN [$NEW_USER];" -C 2>/dev/null || true
    error_exit "Failed to create user [$NEW_USER] in database $DATABASE_NAME"
fi

# Output the connection string for the new user
echo "Connection string for the new user:"
echo "Server=$SERVER_NAME;Database=$DATABASE_NAME;User Id=$NEW_USER;Password=$NEW_USER_PASSWORD;"

