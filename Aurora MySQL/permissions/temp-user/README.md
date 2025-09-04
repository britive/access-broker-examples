# SQL Server Temporary Access Management

This repository contains scripts for managing temporary database access in Azure SQL Server environments through automated creation and cleanup of database users carried out with Britive Access Broker.

## Overview

The solution provides a secure way to grant temporary database access to users by:

- Creating temporary SQL Server logins and database users
- Assigning appropriate database roles
- Automatically cleaning up access when no longer needed

## Scripts

### temp_dba_checkout.sh

Creates a temporary database user with full database owner privileges.

**Functionality:**

1. Extracts username from the provided email address
2. Generates a secure random 12-character password
3. Creates a SQL Server login in the master database
4. Creates a corresponding database user in the target database
5. Assigns the user to the `db_owner` role for full database access
6. Returns connection string for immediate use

### temp_dba_checkin.sh

Removes the temporary database access and cleans up all associated resources.

**Functionality:**

1. Identifies the user to be removed based on email address
2. Terminates all active sessions for the user
3. Drops the database user from the target database
4. Drops the login from the master database
5. Confirms successful cleanup

## Required Service Account Permissions

The admin service account used by these scripts requires the following minimum permissions:

### Server-Level Permissions (Master Database)

- **ALTER ANY LOGIN** - Required to create and drop SQL Server logins
- **VIEW SERVER STATE** - Required to query `sys.dm_exec_sessions` for active sessions
- **ALTER ANY CONNECTION** - Required to kill user sessions using the KILL command

### Database-Level Permissions (Target Database)

- **ALTER ANY USER** - Required to create and drop database users
- **ALTER ANY ROLE** - Required to add users to database roles (specifically `db_owner`)
- **VIEW DATABASE STATE** - Required to query system views for user existence checks

### Recommended Service Account Setup

```sql
-- Create service account login
CREATE LOGIN [temp_access_service] WITH PASSWORD = 'SecurePassword123!';

-- Grant server-level permissions
GRANT ALTER ANY LOGIN TO [temp_access_service];
GRANT VIEW SERVER STATE TO [temp_access_service];
GRANT ALTER ANY CONNECTION TO [temp_access_service];

-- Grant database-level permissions (run this on each target database)
USE [YourTargetDatabase];
CREATE USER [temp_access_service] FOR LOGIN [temp_access_service];
GRANT ALTER ANY USER TO [temp_access_service];
GRANT ALTER ANY ROLE TO [temp_access_service];
GRANT VIEW DATABASE STATE TO [temp_access_service];
```

## Environment Variables set by Profile checkout

Both scripts require the following environment variables to be configured as part of the Britive Resource profile configuration:

| Variable | Description | Example |
|----------|-------------|---------|
| `server_name` | SQL Server instance name | `myserver.database.windows.net` |
| `database_name` | Target database name | `MyDatabase` |
| `admin_user` | Service account username | `temp_access_service` |
| `admin_password` | Service account password | `SecurePassword123!` |
| `user_email` | Email of user requesting access | `john.doe@company.com` |

## Security Considerations

### Password Security

- Passwords are generated using OpenSSL with 12 characters from a secure character set
- Passwords include uppercase, lowercase, numbers, and special characters
- Each checkout generates a unique password

### Access Control

- Users are granted `db_owner` role, providing full database access
- Consider implementing more granular permissions based on use case requirements
- Access is temporary by design - checkin script removes all traces

### Session Management

- Checkin script properly terminates all active sessions before cleanup
- Prevents orphaned connections that could cause login deletion failures

## Troubleshooting

### Aurora MySQL Issues

- **AWS CLI authentication fails**: Verify IAM permissions and AWS credentials configuration
- **Secrets Manager access denied**: Check IAM policy and secret ARN
- **MySQL connection fails**: Verify security groups, VPC settings, and endpoint accessibility
- **User creation fails**: Ensure service account has CREATE USER privileges
- **Grant failures**: Verify service account has GRANT OPTION on target database

## Dependencies

- **OpenSSL**: Used for secure password generation
- **Bash**: Scripts are written for bash shell environments
