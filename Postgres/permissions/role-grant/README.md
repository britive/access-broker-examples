# PostgreSQL Role Grant Scripts

This directory contains scripts for granting and revoking specific PostgreSQL roles to **existing** users. These scripts enable fine-grained, role-based access control at the table and schema level.

## Overview

The role grant scripts provide just-in-time access by assigning pre-defined database roles to users who already have a PostgreSQL account. This is the least-privilege approach — users get exactly the permissions defined by the role, nothing more.

> **Important:** These scripts do **not** create users. The PostgreSQL user must already exist before roles can be granted. Use the `superuser` or `dba-access` scripts to create users first, or provision them through your identity provider.

## Scripts

| Script | Purpose |
| --- | --- |
| `postgres-access-checkout.sh` | Grants a specific role to an existing user |
| `postgres-access-checkin.sh` | Revokes a specific role from a user |

## Prerequisites

### Service Account Requirements

The service account needs the ability to grant and revoke specific roles. Use the narrowest privilege that works:

```sql
-- Connect as a superuser (e.g., postgres)
CREATE USER britive_role_service WITH
    LOGIN
    PASSWORD 'secure_random_password';

-- Preferred: grant only the specific roles this service account manages
GRANT read_only_role TO britive_role_service WITH ADMIN OPTION;
GRANT analyst_role   TO britive_role_service WITH ADMIN OPTION;

-- Alternative: broader role management (less preferred)
-- ALTER USER britive_role_service WITH CREATEROLE;
```

### Role Preparation

Roles must be created in the database before these scripts can grant them:

```sql
-- Read-only access (SELECT only)
CREATE ROLE read_only_role;
GRANT CONNECT ON DATABASE your_db TO read_only_role;
GRANT USAGE ON SCHEMA public TO read_only_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO read_only_role;
-- Also apply to tables created in the future
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO read_only_role;

-- Analyst access (read + temp tables)
CREATE ROLE analyst_role;
GRANT read_only_role TO analyst_role;
GRANT TEMP ON DATABASE your_db TO analyst_role;

-- Application access (specific table write access)
CREATE ROLE app_role;
GRANT CONNECT ON DATABASE your_db TO app_role;
GRANT USAGE ON SCHEMA public TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON specific_table TO app_role;
```

### System Requirements

- `bash` (version 4.0+)
- `psql` (PostgreSQL client)

## Usage

### Granting a Role (checkout)

```bash
BRITIVE_USER=user@company.com \
svc_user=britive_role_service \
svc_password=service_account_password \
db_host=postgres.example.com \
db_name=production_db \
role_name=read_only_role \
./postgres-access-checkout.sh
```

### Revoking a Role (checkin)

```bash
BRITIVE_USER=user@company.com \
svc_user=britive_role_service \
svc_password=service_account_password \
db_host=postgres.example.com \
db_name=production_db \
role_name=read_only_role \
./postgres-access-checkin.sh
```

## Environment Variables

| Variable | Description | Required | Example |
| --- | --- | --- | --- |
| `BRITIVE_USER` | User email address (auto-set by Britive platform) | Yes | `john.doe@company.com` |
| `svc_user` | Service account username | Yes | `britive_role_service` |
| `svc_password` | Service account password | Yes | `secure_password123` |
| `db_host` | PostgreSQL server hostname | Yes | `postgres.example.com` |
| `db_name` | Target database name | Yes | `production_db` |
| `role_name` | Name of the role to grant or revoke | Yes | `read_only_role` |

> **Note:** `BRITIVE_USER` is automatically populated by the Britive platform with the requesting user's email address when run as part of a checkout/checkin flow.

## Username Generation

The PostgreSQL username is derived from the email local-part with all non-alphanumeric characters removed:

- `john.doe@company.com` → `johndoe`
- `jane_smith@company.com` → `janesmith`

## Script Details

### checkout

1. Validates all required environment variables
2. Derives and validates the PostgreSQL username from the email
3. Tests database connectivity with the service account
4. Verifies the target role exists in the database (fails fast if not)
5. Verifies the user exists (fails fast with a clear message if not)
6. Checks if the user already has the role — exits cleanly if so (idempotent)
7. Grants the role to the user
8. Verifies the grant was applied

### checkin

1. Validates all required environment variables
2. Derives and validates the PostgreSQL username from the email
3. Tests database connectivity with the service account
4. Verifies the target role exists in the database (fails fast if not)
5. Checks if the user exists — exits cleanly if not (idempotent)
6. Checks if the user currently has the role — exits cleanly if not (idempotent)
7. Revokes the role from the user
8. Verifies the revocation was applied

## Security Features

- **Input Validation**: All environment variables are validated before any database operations
- **Fail Fast**: `set -euo pipefail` stops the script immediately on any error
- **Idempotent**: Both scripts handle already-granted / already-revoked states gracefully
- **Existence Checks**: Verifies roles and users exist before attempting operations
- **No User Creation**: Scope is limited to role assignment only — no ability to create accounts

## Role Inheritance

PostgreSQL roles can inherit permissions from other roles. When you grant a role that inherits from other roles, the user automatically gets all inherited permissions.

```text
read_only_role  ←  analyst_role  ←  report_writer_role
(SELECT)           (+ TEMP)          (+ INSERT/UPDATE)
```

Granting `report_writer_role` gives the user all three levels of access.

## Troubleshooting

1. **"User does not exist in database"**
   - Create the user first using the `superuser` or `dba-access` scripts
   - Confirm the derived username (`johndoe`) matches what exists in PostgreSQL
   - Verify the user was created in the correct database

2. **"Role does not exist in database"**
   - Create the role in PostgreSQL before running this script
   - Check for typos in `role_name` (case-sensitive)

3. **"Cannot connect to database with service account"**
   - Verify `svc_password` and `db_host` are correct
   - Confirm the service account has `LOGIN` and network access to the server

4. **"Failed to grant/revoke role"**
   - Verify the service account has `ADMIN OPTION` on the target role, or `CREATEROLE`

### Debug Mode

Add `set -x` immediately after `set -euo pipefail` to print every command as it executes.

## Best Practices

1. **Role Design**: Model roles after business access patterns (e.g., `finance_read`, `ops_write`) rather than technical permission sets
2. **Role Inheritance**: Use inheritance to build layered permission levels rather than granting many roles to a single user
3. **Admin Option**: Grant the service account `WITH ADMIN OPTION` on specific roles rather than `CREATEROLE` to limit blast radius
4. **Audit**: Regularly audit role memberships with `SELECT * FROM pg_auth_members` and revoke unused grants

## Differences from Other Access Patterns

| Feature | Role Grant | DBA Access | Superuser |
| --- | --- | --- | --- |
| **Privilege level** | Fine-grained (specific role) | High (monitoring + DBA ops) | Highest (full server admin) |
| **User creation** | No (user must exist) | Yes (temporary user) | Yes (temporary user) |
| **Credential management** | Environment variables | AWS Secrets Manager | Environment variables |
| **External dependencies** | None | AWS CLI, jq, openssl | None |
