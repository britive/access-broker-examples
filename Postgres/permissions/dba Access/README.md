# PostgreSQL DBA Access Scripts

This directory contains scripts for granting and revoking DBA (Database Administrator) privileges on PostgreSQL databases using AWS Secrets Manager for credential management.

## Overview

The DBA access scripts provide just-in-time access by creating temporary PostgreSQL users with full DBA privileges. These scripts are designed for high-privilege access scenarios where users need administrative capabilities.

## Scripts

| Script | Purpose |
|--------|---------|
| `grant_dba_access.sh` | Creates a temporary user with DBA privileges |
| `revoke_dba_access.sh` | Removes DBA privileges and deletes the temporary user |

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
CREATE USER britive_service_account WITH 
    LOGIN 
    CREATEROLE 
    PASSWORD 'secure_random_password';

-- Grant database ownership or specific privileges
GRANT ALL PRIVILEGES ON DATABASE your_database TO britive_service_account WITH GRANT OPTION;

-- Optional: Grant system roles for monitoring capabilities
GRANT pg_monitor TO britive_service_account;
GRANT pg_signal_backend TO britive_service_account;
```

### AWS Prerequisites

1. **AWS CLI**: Installed and configured with appropriate credentials
2. **IAM Permissions**: The executing environment must have:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "secretsmanager:GetSecretValue"
         ],
         "Resource": "arn:aws:secretsmanager:region:account:secret:your-secret-name*"
       }
     ]
   }
   ```

3. **AWS Secrets Manager Secret**: Must contain PostgreSQL connection details in JSON format:
   ```json
   {
     "host": "your-postgres-host.amazonaws.com",
     "port": 5432,
     "username": "britive_service_account", 
     "password": "service_account_password"
   }
   ```

### System Requirements

- `bash` (version 4.0+)
- `psql` (PostgreSQL client)
- `aws` (AWS CLI)
- `jq` (JSON processor)
- `openssl` (for password generation)

## Setup

1. Store your RDS DB credentials in AWS Secrets Manager in the JSON format shown above

2. Set the required environment variables:
   ```bash
   export SECRET_NAME="your-secret-name"
   export DB_NAME="your-db-name"
   export USER_EMAIL="user@example.com"
   ```

3. (Optional) Create AWS Resources using CloudFormation:
   ```bash
   aws cloudformation deploy \
     --template-file aws_sample_db.yaml \
     --stack-name postgres-rds-stack \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides DBPassword=YourSecurePassword VpcId=vpc-xxxx SubnetIds='["subnet-aaa","subnet-bbb"]'
   ```

## Usage

### Granting DBA Access

```bash
SECRET_NAME=my-postgres-secret \
USER_EMAIL=user@company.com \
DB_NAME=production_db \
./grant_dba_access.sh
```

**Output**: JSON configuration for PostgreSQL client tools (pgAdmin, DBeaver, etc.)

### Revoking DBA Access

```bash
SECRET_NAME=my-postgres-secret \
USER_EMAIL=user@company.com \
DB_NAME=production_db \
./revoke_dba_access.sh
```

## Environment Variables

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `SECRET_NAME` | AWS Secrets Manager secret name | Yes | `prod-postgres-credentials` |
| `USER_EMAIL` | User email (used to generate username) | Yes | `john.doe@company.com` |
| `DB_NAME` | Target database name | Yes | `production_db` |

## Security Features

- **Input Validation**: All inputs are validated for format and safety
- **Error Handling**: Comprehensive error handling with cleanup on failure
- **Secure Password Generation**: Uses OpenSSL for cryptographically secure passwords
- **Session Termination**: Terminates active user sessions before cleanup
- **Credential Protection**: Database passwords are never logged or displayed

## Privileges Granted

Temporary DBA users receive the following privileges:

- `ALL PRIVILEGES ON DATABASE` - Full database access
- `pg_monitor` - Database monitoring capabilities  
- `pg_signal_backend` - Ability to terminate other user sessions

## Username Generation

Usernames are generated from email addresses:

- Extract local part (before @)
- Replace dots and hyphens with underscores
- Remove special characters
- Example: `john.doe@company.com` → `john_doe`

## Troubleshooting

### Common Issues

1. **"Cannot connect to database"**
   - Verify service account credentials in AWS Secrets Manager
   - Check network connectivity to PostgreSQL server
   - Ensure service account has LOGIN privilege

2. **"Failed to create user"**
   - Verify service account has CREATEROLE privilege
   - Check if username already exists
   - Ensure database name is correct

3. **"Failed to grant privileges"**
   - Verify service account has GRANT OPTION on target database
   - Check database ownership or privilege delegation

4. **AWS Secrets Manager errors**
   - Verify IAM permissions for secrets access
   - Check secret name and region
   - Ensure secret contains valid JSON with required keys

### Debug Mode

Enable debug output by adding `set -x` to scripts:
```bash
set -euo pipefail
set -x  # Add this line for debug output
```

## Best Practices

1. **Least Privilege**: Service accounts should only have necessary permissions
2. **Secret Rotation**: Regularly rotate service account passwords
3. **Session Timeout**: Implement automatic session timeouts in your access management system
4. **Audit Logging**: Enable PostgreSQL logging to track DBA activities
5. **Network Security**: Use encrypted connections (SSL/TLS) to PostgreSQL

## Integration Notes

These scripts are designed to work with access management platforms like Britive, but can be adapted for other just-in-time access systems.
