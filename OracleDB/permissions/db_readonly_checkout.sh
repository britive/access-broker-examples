#!/bin/bash


# Database Environment Variables
DB_HOST="your-db-host"
DB_PORT="1521"
DB_SERVICE_NAME="your-db-service"
DB_USER="your-username"
DB_PASS="your-password"
USERNAME=$user
TABLE_NAME=$table

# Generate a random password (12 characters, alphanumeric) if the user needs to be created
USER_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)


# Check if the user exists in the Oracle Database
USER_EXISTS=$(sqlplus -s "$DB_USER/$DB_PASS@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$DB_HOST)(PORT=$DB_PORT))(CONNECT_DATA=(SERVICE_NAME=$DB_SERVICE_NAME)))" <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT 'EXISTS' FROM dba_users WHERE username = UPPER('$USERNAME');
EXIT;
EOF
)

if [[ "$USER_EXISTS" == "EXISTS" ]]; then
    echo "User $USERNAME already exists."
else
    echo "User $USERNAME does not exist. Creating user with a generated password."

    # Create the user if they do not exist
    sqlplus -s "$DB_USER/$DB_PASS@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$DB_HOST)(PORT=$DB_PORT))(CONNECT_DATA=(SERVICE_NAME=$DB_SERVICE_NAME)))" <<EOF
CREATE USER $USERNAME IDENTIFIED BY "$USER_PASSWORD";
GRANT CREATE SESSION TO $USERNAME;
EXIT;
EOF

    if [ $? -eq 0 ]; then
        echo "User $USERNAME created successfully with password: $USER_PASSWORD"
    else
        echo "Failed to create user $USERNAME."
        exit 1
    fi
fi


# Execute SQL command to grant SELECT privilege on the specified table
sqlplus -s "$DB_USER/$DB_PASS@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$DB_HOST)(PORT=$DB_PORT))(CONNECT_DATA=(SERVICE_NAME=$DB_SERVICE_NAME)))" <<EOF
GRANT SELECT ON $TABLE_NAME TO $USERNAME;
EXIT;
EOF

if [ $? -eq 0 ]; then
    echo "Read-only access granted on table $TABLE_NAME to user $USERNAME successfully."
else
    echo "Failed to grant read-only access on table $TABLE_NAME to user $USERNAME."
    exit 1
fi