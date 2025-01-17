
# Microsoft SQL Server Management for DB Owner

This permission dir provides Bash scripts to manage MS SQL identities, specifically for adding and removing a user with set permissions on the MS SQL Server.

## Overview

This script automates the process of creating a new SQL Server login and database user based on an email address. It generates a random password for the new user, assigns them full administrative privileges in the specified database, and outputs the connection string for the new user.

## Prerequisites

- `sqlcmd` tool installed. Refer to [this link](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-setup-tools?view=sql-server-ver16&tabs=ubuntu-install#ubuntu) for more details.
- `openssl` installed for password generation.
- Environment variables SERVER_NAME, DATABASE_NAME, ADMIN_USER, ADMIN_PASSWORD, and EMAIL must be set in the profile via the Britive UI. Britive rEsource management configuration must include these variables to successfully run this routine.
  - SERVER_NAME: The name of the SQL Server.
  - DATABASE_NAME: The name of the target database.
  - ADMIN_USER: The administrator username with sufficient privileges to create logins and users.
  - ADMIN_PASSWORD: The password for the administrator.
  - EMAIL: The email address from which the new user's username will be derived.

## Script Functionality

### Checkout Script **temp_dba_checkout.sh**

- Password Generation: The script includes a function generate_password to create a random 12-character password.
- User Creation: The script:
  - Extracts the prefix from the provided email to use as the new SQL Server login and user.
  - Generates and displays a random password for the new user.
  - Executes SQL commands to create the login in the master database.
  - Creates the corresponding user in the specified target database with full admin privileges (db_owner).
- Connection String: The script outputs the connection string for the newly created user, which can be used to connect to the SQL Server.

### Checkin Script **temp_dba_checkin.sh**

- User Identification: The script extracts the prefix from the provided email to determine the username to be deleted.
- Session Termination:
  - Queries active sessions for the specified user.
  - Iterates through each session ID and terminates it using the KILL command to ensure no active connections remain.
- User Deletion:
  - Executes SQL commands to drop the user from the specified database if it exists.
  - Drops the associated login from the master database.

## Notes

- The generated password and connection string will be displayed in the Britive checkout output.
- The script assumes the sqlcmd utility is located at /opt/mssql-tools18/bin/sqlcmd. Adjust this path as necessary based on your system configuration.
