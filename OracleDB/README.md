# Oracle Database Access Broker Scripts

This project provides shell scripts for the Britive Access Broker to manage just-in-time (JIT) Oracle Database permissions. These scripts enable temporary privilege escalation for users and automatic revocation after access is no longer needed.

## Scripts Overview

### permissions/

| Script | Description |
| ------ | ----------- |
| `db_admin_checkout.sh` | Grants the `DBA` role to a user. Creates the user with a randomly generated password if they don't exist, then grants full DBA privileges. |
| `db_admin_checkin.sh` | Revokes the `DBA` role from a user, removing administrative privileges. |
| `db_readonly_checkout.sh` | Grants `SELECT` access on a specific table to a user. Creates the user if they don't exist, then grants read-only access to the specified table. |
| `db_readonly_checkin.sh` | Revokes `SELECT` access on a specific table from a user, removing read-only privileges. |

### Script Variables

Each script expects the following environment variables to be configured:

| Variable | Description |
| -------- | ----------- |
| `DB_HOST` | Oracle Database host address |
| `DB_PORT` | Database port (default: 1521) |
| `DB_SERVICE_NAME` | Oracle service name |
| `DB_USER` | Service account username for script execution |
| `DB_PASS` | Service account password |
| `user` | Target username (passed by Britive) |
| `table` | Target table name (for readonly scripts, passed by Britive) |

## Prerequisites

### Oracle Database Service Account

The Britive Access Broker requires a service account with sufficient privileges to manage user access. The service account (`DB_USER`) needs the following minimum permissions:

#### For DBA Role Management (`db_admin_checkout.sh` / `db_admin_checkin.sh`)

```sql
-- Ability to query existing users
GRANT SELECT ON dba_users TO <service_account>;

-- Ability to create users
GRANT CREATE USER TO <service_account>;

-- Ability to grant/revoke session privileges
GRANT ALTER USER TO <service_account>;

-- Ability to grant/revoke DBA role (requires ADMIN OPTION)
GRANT DBA TO <service_account> WITH ADMIN OPTION;
```

#### For Read-Only Access Management (`db_readonly_checkout.sh` / `db_readonly_checkin.sh`)

```sql
-- Ability to query existing users
GRANT SELECT ON dba_users TO <service_account>;

-- Ability to create users
GRANT CREATE USER TO <service_account>;

-- Ability to grant session privileges to new users
GRANT ALTER USER TO <service_account>;

-- Ability to grant/revoke SELECT on target tables (requires GRANT OPTION)
GRANT SELECT ON <schema>.<table> TO <service_account> WITH GRANT OPTION;
```

### Network & Connectivity

- The Britive Access Broker must have network access to the Oracle Database on the configured port (default: 1521)
- Oracle SQL*Plus client must be installed on the broker host
- TNS connectivity must be properly configured

### Oracle Database Versions

These scripts are compatible with modern Oracle Database infrastructure including:

- Oracle Database 19c and later
- Oracle Autonomous Database (ATP/ADW)
- Oracle Database Cloud Service
- Oracle Exadata Cloud Service
