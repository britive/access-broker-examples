# PostgreSQL DBA Access Scripts

This directory contains scripts for granting and revoking DBA-level privileges on PostgreSQL databases using **AWS Secrets Manager** for service account credential management.

## Overview

The DBA access scripts provide just-in-time access by creating temporary PostgreSQL users with elevated monitoring and management privileges. This pattern differs from the superuser pattern in that credentials are retrieved from AWS Secrets Manager rather than passed as environment variables, and the privilege level is scoped to monitoring/management rather than full server admin.

An optional CloudFormation template (`aws_sample_db.yml`) is included to provision a sample RDS PostgreSQL instance for testing.

## Scripts

| Script | Purpose |
| --- | --- |
| `grant_dba_access.sh` | Creates a temporary user with DBA privileges |
| `revoke_dba_access.sh` | Removes DBA privileges and deletes the temporary user |

## Prerequisites

### Service Account Requirements

The service account credentials are stored in AWS Secrets Manager. That account must have:

#### Database Server Level

- `CREATEROLE` — ability to create and drop database roles/users
- `LOGIN` — ability to connect to the database

#### Database Level

- `OWNER` privileges on the target database, OR
- `GRANT OPTION` on all privileges you want to delegate

#### Sample Service Account Setup

```sql
-- Connect as a superuser (e.g., postgres)
CREATE USER britive_service_account WITH
    LOGIN
    CREATEROLE
    PASSWORD 'secure_random_password';

-- Grant database-level privileges with delegation rights
GRANT ALL PRIVILEGES ON DATABASE your_database TO britive_service_account WITH GRANT OPTION;

-- Grant system roles the service account will delegate
GRANT pg_monitor TO britive_service_account WITH ADMIN OPTION;
GRANT pg_signal_backend TO britive_service_account WITH ADMIN OPTION;
```

### AWS Prerequisites

1. **AWS CLI** installed and configured with appropriate credentials

2. **IAM Permissions** — the executing environment must allow:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:region:account:secret:your-secret-name*"
    }
  ]
}
```

1. **AWS Secrets Manager Secret** containing the service account credentials in this exact JSON format:

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
- `openssl` (for password generation — grant script only)

## Setup

1. Store your RDS service account credentials in AWS Secrets Manager using the JSON format above.

2. Set the required environment variables:

```bash
export SECRET_NAME="your-secret-name"
export DB_NAME="your-db-name"
export BRITIVE_USER="user@example.com"
```

1. (Optional) Deploy a sample RDS instance using the included CloudFormation template:

```bash
aws cloudformation deploy \
  --template-file aws_sample_db.yml \
  --stack-name postgres-rds-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      DBPassword=YourSecurePassword \
      VpcId=vpc-xxxx \
      SubnetIds='["subnet-aaa","subnet-bbb"]'
```

## Usage

### Granting DBA Access (checkout)

```bash
BRITIVE_USER=user@company.com \
SECRET_NAME=my-postgres-secret \
DB_NAME=production_db \
./grant_dba_access.sh
```

**Output**: JSON connection configuration for PostgreSQL clients (pgAdmin, DBeaver, etc.).

### Revoking DBA Access (checkin)

```bash
BRITIVE_USER=user@company.com \
SECRET_NAME=my-postgres-secret \
DB_NAME=production_db \
./revoke_dba_access.sh
```

## Environment Variables

| Variable | Description | Required | Example |
| --- | --- | --- | --- |
| `BRITIVE_USER` | User email address (auto-set by Britive platform) | Yes | `john.doe@company.com` |
| `SECRET_NAME` | AWS Secrets Manager secret name containing service account credentials | Yes | `prod-postgres-credentials` |
| `DB_NAME` | Target database name | Yes | `production_db` |

> **Note:** `BRITIVE_USER` is automatically populated by the Britive platform with the requesting user's email address when run as part of a checkout/checkin flow.

## Username Generation

The PostgreSQL username is derived from the email local-part with dots and hyphens replaced by underscores:

- `john.doe@company.com` → `john_doe`
- `jane-smith@company.com` → `jane_smith`

## Privileges Granted

| Privilege | What It Enables |
| --- | --- |
| `ALL PRIVILEGES ON DATABASE` | CONNECT, CREATE schemas, CREATE TEMP tables |
| `pg_monitor` | Query `pg_stat_*` views, read server logs |
| `pg_signal_backend` | Terminate other backend sessions |

> **Note:** This does not grant table-level `SELECT`/`INSERT`/etc. To grant data access, use the role-grant scripts with an appropriate role.

## Script Details

### grant_dba_access.sh

1. Validates all required environment variables and tools
2. Retrieves service account credentials from AWS Secrets Manager
3. Validates the JSON credentials response
4. Derives and validates the PostgreSQL username from the email
5. Generates a cryptographically secure 32-byte base64 password
6. Tests database connectivity
7. If user already exists: terminates sessions, reassigns owned objects, drops user
8. Creates the role and grants DBA-level privileges
9. Outputs connection JSON for the Britive access panel

### revoke_dba_access.sh

1. Validates all required environment variables and tools
2. Retrieves service account credentials from AWS Secrets Manager
3. Derives and validates the PostgreSQL username from the email
4. Tests database connectivity
5. Checks if user exists (exits cleanly if not — idempotent)
6. Terminates all active sessions for the user
7. Reassigns any owned objects to the service account (`REASSIGN OWNED BY`)
8. Drops all remaining privileges and objects (`DROP OWNED BY`)
9. Drops the role

## Security Features

- **Input Validation**: Email format, database name, and all generated values are validated
- **Fail Fast**: `set -euo pipefail` stops the script immediately on any error
- **Secure Password Generation**: `openssl rand -base64 32` produces a cryptographically secure password
- **No Credential Logging**: Passwords are never written to logs or stdout (except the one-time connection JSON output on checkout)
- **Session Cleanup**: Active sessions are terminated before user removal
- **Owned Object Handling**: `REASSIGN OWNED BY` prevents `DROP ROLE` failures caused by objects the temp user may have created

## Troubleshooting

1. **"Cannot connect to database"**
   - Verify the secret JSON contains correct host/port/username/password
   - Check network connectivity and security group rules to the RDS instance
   - Confirm the service account has `LOGIN` privilege

2. **"Failed to retrieve secret from AWS Secrets Manager"**
   - Verify IAM permissions include `secretsmanager:GetSecretValue` on the secret ARN
   - Check the secret name and AWS region configuration

3. **"Invalid JSON received from AWS Secrets Manager"**
   - Ensure the secret value is valid JSON with the required keys: `host`, `port`, `username`, `password`

4. **"Generated username contains invalid characters"**
   - The email local-part must start with a letter after substituting `.` and `-` with `_`

### Debug Mode

Add `set -x` immediately after `set -euo pipefail` to print every command as it executes.

## Best Practices

1. **Secret Rotation**: Regularly rotate service account passwords in Secrets Manager
2. **Least Privilege**: The service account should have only the privileges listed above — not SUPERUSER
3. **Audit Logging**: Enable PostgreSQL `log_connections` and `log_statement` for audit trails
4. **Network Security**: Use SSL/TLS connections (the output JSON sets `"SSLMode": "prefer"`)
5. **Short Sessions**: Configure short checkout durations in Britive (e.g., 2–4 hours)

## Differences from Other Access Patterns

| Feature | DBA Access | Superuser | Role Grant |
| --- | --- | --- | --- |
| **Privilege level** | High (monitoring + DBA ops) | Highest (full server admin) | Fine-grained (specific role) |
| **User creation** | Yes (temporary user) | Yes (temporary user) | No (user must exist) |
| **Credential management** | AWS Secrets Manager | Environment variables | Environment variables |
| **External dependencies** | AWS CLI, jq, openssl | None | None |
