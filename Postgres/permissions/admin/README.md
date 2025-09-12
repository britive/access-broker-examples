# PostgreSQL Admin Access Scripts

This directory contains scripts for granting and revoking admin privileges on PostgreSQL databases. These scripts create temporary users with full admin privileges on a specific database.

## Overview

The admin access scripts provide just-in-time admin-level access by creating temporary PostgreSQL users with comprehensive database privileges. These scripts are designed for scenarios where users need extensive database permissions but not server-level DBA capabilities.

## Scripts

| Script | Purpose |
|--------|---------|
| `postgres-adminaccess-checkout.sh` | Creates a temporary user with admin privileges |
| `postgres-adminaccess-checkin.sh` | Removes admin privileges and deletes the temporary user |

## Prerequisites

### Service Account Requirements

The service account used by these scripts must have the following PostgreSQL privileges:

#### Database Server Level

- `CREATEROLE` - Ability to create and drop database roles/users
- `LOGIN` - Ability to connect to the database
- Connection access to the target database

#### Database Level  

- `OWNER` privileges on the target database, OR
- `GRANT OPTION` on all privileges you want to delegate to temporary users

#### Sample Service Account Creation
```sql
-- Connect as a superuser (e.g., postgres)
CREATE USER britive_admin_service WITH 
    LOGIN 
    CREATEROLE 
    PASSWORD 'secure_random_password';

-- Grant database ownership or specific privileges
GRANT ALL PRIVILEGES ON DATABASE your_database TO britive_admin_service WITH GRANT OPTION;

-- Allow the service account to manage users
GRANT USAGE ON SCHEMA public TO britive_admin_service;
GRANT CREATE ON SCHEMA public TO britive_admin_service;
```

### System Requirements

- `bash` (version 4.0+)
- `psql` (PostgreSQL client)
- `tr` (text processing utility)

## Usage

### Granting Admin Access

```bash
user=user@company.com \
svc_user=britive_admin_service \
svc_password=service_account_password \
db_host=postgres.example.com \
db_name=production_db \
./postgres-adminaccess-checkout.sh
```

**Output**: Connection command for the new temporary user

### Revoking Admin Access

```bash
user=user@company.com \
svc_user=britive_admin_service \
svc_password=service_account_password \
host=postgres.example.com \
db_name=production_db \
./postgres-adminaccess-checkin.sh
```

## Environment Variables

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `user` | User email (used to generate username) | Yes | `john.doe@company.com` |
| `svc_user` | Service account username | Yes | `britive_admin_service` |
| `svc_password` | Service account password | Yes | `secure_password123` |
| `db_host` | PostgreSQL server hostname | Yes (checkout) | `postgres.example.com` |
| `host` | PostgreSQL server hostname | Yes (checkin) | `postgres.example.com` |
| `db_name` | Target database name | Yes | `production_db` |

## Security Features

- **Input Validation**: All inputs are validated for format and safety
- **Error Handling**: Comprehensive error handling with cleanup on failure
- **Secure Password Generation**: Uses `/dev/urandom` for cryptographically secure passwords
- **Session Termination**: Terminates active user sessions before cleanup
- **Username Sanitization**: Extracts and sanitizes usernames from email addresses

## Privileges Granted

Temporary admin users receive the following privileges:

- `ALL PRIVILEGES ON DATABASE` - Full database access including:
  - `CONNECT` - Ability to connect to the database
  - `CREATE` - Ability to create schemas and objects
  - `TEMPORARY` - Ability to create temporary tables
  - All schema-level privileges within the database

## Username Generation

Usernames are generated from email addresses:

- Extract local part (before @)
- Remove all special characters except alphanumeric
- Example: `john.doe@company.com` → `johndoe`

## Script Details

### postgres-adminaccess-checkout.sh

- Creates or recreates PostgreSQL user
- Generates secure 16-character password
- Grants full database privileges
- Tests connection to verify user creation
- Provides connection details for immediate use

### postgres-adminaccess-checkin.sh

- Checks if user exists before attempting cleanup
- Revokes all database privileges
- Terminates active user sessions
- Drops the user completely
- Verifies successful cleanup

## Troubleshooting

### Common Issues

1. **"Cannot connect to database with service account"**
   - Verify service account credentials are correct
   - Check network connectivity to PostgreSQL server
   - Ensure service account has LOGIN privilege
   - Verify database name is correct

2. **"Failed to create user"**
   - Verify service account has CREATEROLE privilege
   - Check if username already exists (script will recreate)
   - Ensure database name is valid

3. **"Failed to grant privileges"**
   - Verify service account has GRANT OPTION on target database
   - Check database ownership or privilege delegation
   - Ensure database exists and is accessible

4. **"Failed to verify new user connection"**
   - Check if PostgreSQL allows new connections
   - Verify connection limits haven't been exceeded
   - Ensure generated password doesn't contain conflicting characters

### Debug Mode

Enable debug output by modifying the scripts:
```bash
set -euo pipefail
set -x  # Add this line for debug output
```

## Security Considerations

1. **Password Security**: Generated passwords are 16 characters with mixed complexity
2. **Session Cleanup**: Active sessions are terminated before user deletion
3. **Privilege Isolation**: Users only get database-level privileges, not server-level
4. **Audit Trail**: All database operations are logged by PostgreSQL
5. **Temporary Access**: Users are designed to be short-lived

## Best Practices

1. **Service Account Management**: 
   - Use dedicated service accounts with minimal required privileges
   - Rotate service account passwords regularly
   - Store service credentials securely (consider using secrets management)

2. **Access Control**:
   - Implement session timeouts in your access management system
   - Monitor and audit temporary user activities
   - Use network-level restrictions where possible

3. **Error Handling**:
   - Monitor script execution for failures
   - Implement alerting for failed cleanup operations
   - Regular cleanup of orphaned users

## Integration Notes

These scripts are designed to work with access management platforms but can be adapted for other just-in-time access systems. The scripts use environment variables for configuration, making them suitable for automation and CI/CD pipelines.

## Differences from DBA Access

- **Scope**: Database-level privileges only (not server-level DBA privileges)
- **Credential Management**: Uses direct environment variables instead of AWS Secrets Manager
- **User Management**: Simpler user lifecycle without advanced role management
- **Dependencies**: Fewer external dependencies (no AWS CLI, jq, or openssl required)