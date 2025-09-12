# PostgreSQL Role-Based Access Scripts

This directory contains scripts for granting and revoking specific PostgreSQL roles to existing users. These scripts manage role-based permissions for table and schema-level access control.

## Overview

The role-based access scripts provide just-in-time access by granting specific PostgreSQL roles to existing users. These scripts are designed for fine-grained access control where users need specific permissions defined by pre-existing database roles.

## Scripts

| Script | Purpose |
|--------|---------|
| `postgres-access-checkout.sh` | Grants a specific role to an existing user |
| `postgres-access-checkin.sh` | Revokes a specific role from a user |

## Prerequisites

### Service Account Requirements

The service account used by these scripts must have the following PostgreSQL privileges:

#### Database Server Level

- `LOGIN` - Ability to connect to the database
- Connection access to the target database
- Membership in roles that need to be granted (with `GRANT OPTION`), OR
- `CREATEROLE` privilege for broader role management

#### Role Management Privileges

For each role you want to manage, the service account needs:

- `GRANT OPTION` on that specific role, OR
- The role must be granted to the service account `WITH ADMIN OPTION`

#### Sample Service Account Setup
```sql
-- Connect as a superuser (e.g., postgres)
CREATE USER britive_role_service WITH 
    LOGIN 
    PASSWORD 'secure_random_password';

-- Grant specific roles with admin option (preferred approach)
GRANT read_only_role TO britive_role_service WITH ADMIN OPTION;
GRANT analyst_role TO britive_role_service WITH ADMIN OPTION; 
GRANT report_writer_role TO britive_role_service WITH ADMIN OPTION;

-- Alternative: Grant CREATEROLE for broader access
-- GRANT CREATEROLE TO britive_role_service;
```

### Role Preparation

Before using these scripts, you must have pre-existing roles defined in your PostgreSQL database:

```sql
-- Example: Create role-based access levels
CREATE ROLE read_only_role;
GRANT CONNECT ON DATABASE your_database TO read_only_role;
GRANT USAGE ON SCHEMA public TO read_only_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO read_only_role;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO read_only_role;

CREATE ROLE analyst_role;
GRANT read_only_role TO analyst_role;  -- Inherit read permissions
GRANT CREATE TEMP TABLES ON DATABASE your_database TO analyst_role;

CREATE ROLE report_writer_role;
GRANT analyst_role TO report_writer_role;  -- Inherit analyst permissions
GRANT INSERT, UPDATE ON specific_tables TO report_writer_role;
```

### System Requirements

- `bash` (version 4.0+)
- `psql` (PostgreSQL client)

## Usage

### Granting Role Access

```bash
user=user@company.com \
svc_user=britive_role_service \
svc_password=service_account_password \
db_host=postgres.example.com \
db_name=production_db \
role_name=read_only_role \
./postgres-access-checkout.sh
```

### Revoking Role Access

```bash
user=user@company.com \
svc_user=britive_role_service \
svc_password=service_account_password \
db_host=postgres.example.com \
db_name=production_db \
role_name=read_only_role \
./postgres-access-checkin.sh
```

## Environment Variables

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `user` | User email (used to generate username) | Yes | `john.doe@company.com` |
| `svc_user` | Service account username | Yes | `britive_role_service` |
| `svc_password` | Service account password | Yes | `secure_password123` |
| `db_host` | PostgreSQL server hostname | Yes | `postgres.example.com` |
| `db_name` | Target database name | Yes | `production_db` |
| `role_name` | Role to grant/revoke | Yes | `read_only_role` |

## Security Features

- **Input Validation**: All inputs are validated for format and safety
- **Error Handling**: Comprehensive error handling for all operations
- **Existence Checking**: Verifies users and roles exist before operations
- **Idempotent Operations**: Safe to run multiple times
- **Username Sanitization**: Extracts and sanitizes usernames from email addresses

## Role Management Logic

### Grant Process (checkout)

1. Validates all required environment variables
2. Sanitizes and validates username from email
3. Tests database connectivity with service account
4. Verifies the target role exists in the database
5. Verifies the user exists (must be created separately)
6. Checks if user already has the role (exits gracefully if so)
7. Grants the role to the user
8. Verifies the role grant was successful

### Revoke Process (checkin)

1. Validates all required environment variables
2. Sanitizes and validates username from email
3. Tests database connectivity with service account
4. Verifies the target role exists in the database
5. Checks if user exists (exits gracefully if not)
6. Checks if user currently has the role (exits gracefully if not)
7. Revokes the role from the user
8. Verifies the role revocation was successful

## Username Generation

Usernames are generated from email addresses:

- Extract local part (before @)
- Remove all special characters except alphanumeric
- Example: `john.doe@company.com` → `johndoe`

## Important Notes

### User Creation Requirement
**These scripts do NOT create users**. Users must already exist in the database before roles can be granted. Use the admin or DBA access scripts to create users first, or create them manually:

```sql
CREATE USER johndoe WITH LOGIN PASSWORD 'user_password';
```

### Role Inheritance
PostgreSQL roles can inherit from other roles. When you grant a role that inherits from other roles, the user gets all inherited permissions automatically.

## Troubleshooting

### Common Issues

1. **"User does not exist in database"**
   - Create the user first using admin/DBA scripts
   - Verify the username generation matches expected format
   - Check database connectivity and permissions

2. **"Role does not exist in database"**
   - Create the required role in PostgreSQL
   - Verify role name spelling and case sensitivity
   - Check if role exists in the correct database

3. **"Cannot connect to database with service account"**
   - Verify service account credentials are correct
   - Check network connectivity to PostgreSQL server
   - Ensure service account has LOGIN privilege

4. **"Failed to grant/revoke role"**
   - Verify service account has ADMIN OPTION on the target role
   - Check if service account has CREATEROLE privilege
   - Ensure role exists and is grantable

### Debug Mode

Enable debug output by modifying the scripts:
```bash
set -euo pipefail
set -x  # Add this line for debug output
```

## Common Role Patterns

### Read-Only Access
```sql
CREATE ROLE read_only_role;
GRANT CONNECT ON DATABASE your_db TO read_only_role;
GRANT USAGE ON SCHEMA public TO read_only_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO read_only_role;
-- For future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO read_only_role;
```

### Analyst Access (Read + Temp Tables)
```sql
CREATE ROLE analyst_role;
GRANT read_only_role TO analyst_role;
GRANT CREATE TEMP TABLES ON DATABASE your_db TO analyst_role;
```

### Application Access (Specific Tables)
```sql
CREATE ROLE app_role;
GRANT CONNECT ON DATABASE your_db TO app_role;
GRANT USAGE ON SCHEMA public TO app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON specific_table TO app_role;
```

## Best Practices

1. **Role Design**:
   - Create roles that match your business access patterns
   - Use role inheritance to build layered permissions
   - Document role purposes and permissions

2. **Service Account Management**:
   - Grant service accounts only the specific roles they need to manage
   - Use `WITH ADMIN OPTION` instead of `CREATEROLE` when possible
   - Rotate service account passwords regularly

3. **Access Patterns**:
   - Create users through admin/DBA scripts first
   - Grant roles through these scripts second
   - Implement proper session timeouts and monitoring

4. **Maintenance**:
   - Regularly audit role memberships
   - Clean up unused roles and users
   - Monitor for privilege escalation

## Integration Notes

These scripts work best as part of a comprehensive access management system:

1. Use DBA/admin scripts to create users
2. Use role scripts to grant specific permissions
3. Use role scripts to revoke permissions when access expires
4. Use DBA/admin scripts to clean up users when no longer needed

## Differences from Admin/DBA Access

- **Scope**: Role-level permissions only (not user creation or full database access)
- **Granularity**: Fine-grained control over specific permissions
- **User Lifecycle**: Assumes users already exist
- **Permission Model**: Role-based rather than privilege-based