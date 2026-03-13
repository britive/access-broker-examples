# PostgreSQL Superuser Access Scripts

This directory contains scripts for granting and revoking **SUPERUSER** privileges on PostgreSQL databases. These scripts create temporary users with full server-level admin privileges and are designed for just-in-time access scenarios requiring the highest level of database access.

## Overview

A PostgreSQL `SUPERUSER` bypasses all permission checks and has full control over the entire database server — including the ability to create/drop databases and roles, access system catalogs, and read any data. Use this access pattern sparingly and only when a lower-privilege option (e.g., DBA access or a specific role) is insufficient.

## Scripts

| Script | Purpose |
| --- | --- |
| `postgres-adminaccess-checkout.sh` | Creates a temporary SUPERUSER |
| `postgres-adminaccess-checkin.sh` | Removes the temporary user and all its privileges |

## Prerequisites

### Service Account Requirements

The service account must itself be a PostgreSQL `SUPERUSER` — only a superuser can grant the SUPERUSER attribute to another role.

```sql
-- Connect as the postgres superuser
CREATE USER britive_admin_service WITH
    LOGIN
    SUPERUSER
    PASSWORD 'secure_random_password';
```

### System Requirements

- `bash` (version 4.0+)
- `psql` (PostgreSQL client)
- `tr` (standard POSIX utility, pre-installed on all Linux distributions)

#### Installation

**RHEL / CentOS / Rocky Linux / Amazon Linux 2023:**

```bash
sudo dnf install postgresql
```

**Amazon Linux 2:**

```bash
sudo yum install postgresql
```

**Ubuntu / Debian:**

```bash
sudo apt update && sudo apt install postgresql-client
```

**Verification:**

```bash
which psql bash tr && psql --version
```

## Usage

### Granting Superuser Access (checkout)

```bash
BRITIVE_USER=user@company.com \
svc_user=britive_admin_service \
svc_password=service_account_password \
db_host=postgres.example.com \
db_name=production_db \
./postgres-adminaccess-checkout.sh
```

**Output**: Connection command with the generated credentials.

### Revoking Superuser Access (checkin)

```bash
BRITIVE_USER=user@company.com \
svc_user=britive_admin_service \
svc_password=service_account_password \
db_host=postgres.example.com \
db_name=production_db \
./postgres-adminaccess-checkin.sh
```

## Environment Variables

| Variable | Description | Required | Example |
| --- | --- | --- | --- |
| `BRITIVE_USER` | User email address (auto-set by Britive platform) | Yes | `john.doe@company.com` |
| `svc_user` | Service account username | Yes | `britive_admin_service` |
| `svc_password` | Service account password | Yes | `secure_password123` |
| `db_host` | PostgreSQL server hostname | Yes | `postgres.example.com` |
| `db_name` | Target database name | Yes | `production_db` |

> **Note:** `BRITIVE_USER` is automatically populated by the Britive platform with the requesting user's email address when run as part of a checkout/checkin flow.

## Username Generation

The PostgreSQL username is derived from the email local-part with all non-alphanumeric characters removed:

- `john.doe@company.com` → `johndoe`
- `jane_smith@company.com` → `janesmith`

## Privileges Granted

The temporary user receives:

- `SUPERUSER` — full server-level access, including:
  - Create and drop any database or role
  - Bypass all permission checks
  - Access to all system catalogs and configuration
  - Read and write any data in any schema

## Script Details

### checkout

1. Validates all required environment variables
2. Derives and validates the PostgreSQL username from the email
3. Generates a cryptographically secure 16-character password
4. Tests database connectivity with the service account
5. If the user already exists: terminates sessions, reassigns owned objects, drops the user
6. Creates the user and grants `SUPERUSER`
7. Verifies the new user can actually connect

### checkin

1. Validates all required environment variables
2. Derives and validates the PostgreSQL username from the email
3. Tests database connectivity with the service account
4. Checks if the user exists (exits cleanly if not — idempotent)
5. Terminates all active sessions for the user
6. Reassigns any owned objects to the service account (`REASSIGN OWNED BY`)
7. Drops all remaining privileges and objects (`DROP OWNED BY`)
8. Drops the role
9. Verifies the user was successfully removed

## Security Features

- **Input Validation**: All environment variables are validated before any database operations
- **Fail Fast**: `set -euo pipefail` ensures the script stops immediately on any error
- **Secure Password Generation**: 16-character password from `/dev/urandom` using `LC_ALL=C` for locale safety
- **Session Cleanup**: Active sessions are terminated before user removal
- **Owned Object Handling**: `REASSIGN OWNED BY` prevents `DROP ROLE` failures caused by objects the temp user may have created
- **Idempotent Checkin**: Safe to run multiple times — exits cleanly if the user is already gone

## Troubleshooting

1. **"Cannot connect to database with service account"**
   - Verify `svc_password` and `db_host` are correct
   - Confirm `svc_user` has LOGIN privilege and network access to the server

2. **"Failed to verify new user connection"**
   - Check that PostgreSQL `max_connections` has not been reached
   - Verify the server allows connections from this host (pg_hba.conf)

3. **"Invalid username generated"**
   - The email local-part may not start with a letter after stripping special characters
   - Example: `123user@company.com` → `123user` is invalid (starts with a digit)

### Debug Mode

Add `set -x` immediately after `set -euo pipefail` to print every command as it executes.

## Security Considerations

1. **Minimal Duration**: Configure short checkout durations in Britive (e.g., 1–4 hours)
2. **Approval Workflow**: Require manager or security team approval for all SUPERUSER checkouts
3. **Audit Logging**: Enable `log_connections`, `log_disconnections`, and `log_statement = 'all'` in PostgreSQL for full audit trails
4. **Session Limits**: Restrict the service account's `CONNECTION LIMIT` to prevent abuse

## Differences from Other Access Patterns

| Feature | Superuser | DBA Access | Role Grant |
| --- | --- | --- | --- |
| **Privilege level** | Highest (full server admin) | High (monitoring + DBA ops) | Fine-grained (specific role) |
| **User creation** | Yes (temporary user) | Yes (temporary user) | No (user must exist) |
| **Credential management** | Environment variables | AWS Secrets Manager | Environment variables |
| **External dependencies** | None | AWS CLI, jq, openssl | None |
