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

# Validate required environment variables
for var in EMAIL SERVER_NAME DATABASE_NAME ADMIN_USER ADMIN_PASSWORD; do
    if [ -z "${!var}" ]; then
        error_exit "The $var environment variable is not set."
    fi
done

# Extract the prefix from the email to determine the user
EMAIL_PREFIX=$(echo "$EMAIL" | awk -F'@' '{print $1}')

if [ -z "$EMAIL_PREFIX" ]; then
    error_exit "Failed to extract username from email: $EMAIL"
fi

# Sanitize the username
USER_TO_DELETE=$(sanitize_username "$EMAIL_PREFIX")

echo "Original username: $EMAIL_PREFIX"
echo "Sanitized username: $USER_TO_DELETE"

# Step 1: SQL command to find all session IDs (SPIDs) for the login
SQL_FIND_SESSIONS="SELECT session_id FROM sys.dm_exec_sessions WHERE login_name = '$USER_TO_DELETE';"

# Execute the SQL command to find session IDs and store them in a variable
echo "Finding active sessions for user $USER_TO_DELETE..."
SESSION_IDS=$(/opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$SQL_FIND_SESSIONS" -h -1 -W -C 2>/dev/null | grep -E '^[0-9]+$' || true)

# Step 2: Loop through each session ID and kill it
if [ -n "$SESSION_IDS" ]; then
    for SESSION_ID in $SESSION_IDS; do
        echo "Killing session ID: $SESSION_ID"
        SQL_KILL_SESSION="KILL $SESSION_ID;"
        if ! /opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$SQL_KILL_SESSION" -C; then
            echo "Warning: Failed to kill session $SESSION_ID, continuing..."
        fi
    done
else
    echo "No active sessions found for user $USER_TO_DELETE"
fi

# SQL commands to drop the user from the database
SQL_COMMANDS_DATABASE="
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$USER_TO_DELETE')
BEGIN
    DROP USER [$USER_TO_DELETE];
    PRINT 'User [$USER_TO_DELETE] dropped from database';
END
ELSE
BEGIN
    PRINT 'User [$USER_TO_DELETE] does not exist in database';
END
"

# Execute the SQL commands to drop the user from the target database
echo "Dropping user from database $DATABASE_NAME..."
if ! /opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -d "$DATABASE_NAME" -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$SQL_COMMANDS_DATABASE" -C; then
    echo "Warning: Failed to drop user from database, attempting to continue..."
fi

# Check if login exists before attempting to drop
echo "Checking if login exists in master database..."
CHECK_LOGIN="SELECT name, type_desc FROM sys.server_principals WHERE name = '$USER_TO_DELETE';"
echo "DEBUG: Running query: $CHECK_LOGIN"
/opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -d master -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$CHECK_LOGIN" -C

# Execute the DROP LOGIN command directly (simpler approach like original script)
echo "Dropping login from master database..."
SQL_DROP_LOGIN="DROP LOGIN [$USER_TO_DELETE];"
echo "DEBUG: Executing: $SQL_DROP_LOGIN"

# Execute and capture both stdout and stderr
DROP_OUTPUT=$(/opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -d master -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$SQL_DROP_LOGIN" -C 2>&1)
DROP_EXIT_CODE=$?

echo "DEBUG: Drop login exit code: $DROP_EXIT_CODE"
echo "DEBUG: Drop login output: $DROP_OUTPUT"

# Verify the login was actually dropped
echo "Verifying login removal..."
VERIFY_LOGIN="SELECT name FROM sys.server_principals WHERE name = '$USER_TO_DELETE';"
echo "DEBUG: Running verification query: $VERIFY_LOGIN"
VERIFY_OUTPUT=$(/opt/mssql-tools18/bin/sqlcmd -S "$SERVER_NAME" -d master -U "$ADMIN_USER" -P "$ADMIN_PASSWORD" -Q "$VERIFY_LOGIN" -h -1 -W -C 2>&1)

echo "DEBUG: Verification output: $VERIFY_OUTPUT"

# Check if the username appears in the output
if echo "$VERIFY_OUTPUT" | grep -q "$USER_TO_DELETE"; then
    error_exit "Failed to drop login [$USER_TO_DELETE] from master database - login still exists"
fi

echo "Login [$USER_TO_DELETE] verified as removed from server"

echo "User $USER_TO_DELETE and associated login have been deleted successfully."
echo "Checkin completed successfully."
