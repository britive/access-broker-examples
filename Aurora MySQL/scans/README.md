# MySQL / Aurora MySQL Scan

This directory contains a bash script that scans a MySQL or Aurora MySQL endpoint for local accounts, roles, role memberships, and privilege grants, and outputs the data as JSON for downstream processing by the Britive Resource Manager — the same schema used by the [Active Directory scan](../../Active%20Directory/scans/).

### Script: `mysql-scan.sh`

Connects to the database with admin credentials from AWS Secrets Manager, enumerates `mysql.user` and `mysql.role_edges`, captures each account's `SHOW GRANTS` output, and writes the results to a structured JSON file at the path specified by the Britive broker.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full file path for the scan JSON output. Injected by the Britive broker at runtime. |
| `dburl` | Yes | — | RDS / Aurora endpoint hostname |
| `secret` | Yes | — | AWS Secrets Manager secret ID holding admin `{username, password}` |
| `AWS_REGION` | No | `us-west-2` | Secrets Manager region |
| `DB_PORT` | No | `3306` | MySQL port |
| `DB_CA_CERT` | No | — | Path to the [RDS CA bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) on the broker; enables server cert verification. Without it the connection is encrypted but the chain is not verified (MariaDB 11.4+ clients verify by default and reject the RDS CA) |
| `SCAN_EXCLUDE_USERS` | No | `mysql.infoschema,mysql.session,mysql.sys,rdsadmin,rdsrepladmin` | Comma-separated `User` values to skip (system/service accounts) |
| `SCAN_INCLUDE_GRANTS` | No | `1` | `1` captures `SHOW GRANTS` per account into `attributes.grants` (one extra query per account); `0` skips |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` is set (fails immediately if not) and creates the output directory if missing.
2. Fetches admin credentials from Secrets Manager and verifies connectivity.
3. Queries `mysql.user` for all accounts (`User`, `Host`, `account_locked`, `password_expired`).
4. Queries `mysql.role_edges` (MySQL 8+ / Aurora MySQL 3+) for role grants. On engines without it (MySQL 5.7), the groups array is simply empty.
5. Emits accounts as **identities** and roles as **groups**, with each role's grantees as members.
6. Optionally captures `SHOW GRANTS` per account/role into `attributes.grants`.
7. Writes the JSON output to the broker-specified path.
8. On any failure, writes a minimal JSON with the error details so the broker can report the failure back to the platform.

#### Identity Resolution

- **Identity `id`** uses the MySQL account identifier `user@host` (e.g., `alice@%`, `deploy@10.0.0.5`) — unique per account and short enough for native_id column limits.
- **Group `id`** uses the role's `user@host` identifier.
- **Group `members`** arrays contain grantee `user@host` values, matching the identity `id` field so that `attribute_resolution.group_membership = "id"` resolves correctly.
- An account is classified as a **role** (group) when it appears on the `FROM` side of `mysql.role_edges`; role accounts are excluded from the identities array, and role-to-role grants are excluded from member lists.
- `is_active` is `false` when `account_locked = 'Y'`.

#### Output Schema

- **`data.identities`** — all non-role MySQL accounts with attributes: `username`, `host`, `account_locked`, `password_expired`, `grants`.
- **`data.groups`** — MySQL roles with their grantee member lists and attributes: `rolename`, `host`, `account_locked`, `grants`.
- **`data.permissions`** — empty array (permissions are defined in the resource type, not from this scan; privilege detail is captured in `attributes.grants`).
- **`data.permission_mapping`** — empty array (role assignments are captured in `groups.members`).
- **`metadata`** — includes `resource_id` (the endpoint hostname), `resource_type` (`MySQL`), `scan_time`, `scan_details`, `scan_errors`, and `attribute_resolution`.

Example output:

```json
{
  "data": {
    "identities": [
      {
        "id": "alice@%",
        "name": "alice@%",
        "type": "User",
        "description": "MySQL local account",
        "created_on": "2026-07-15T00:00:00Z",
        "is_active": true,
        "attributes": {
          "username": "alice",
          "host": "%",
          "account_locked": "N",
          "password_expired": "N",
          "grants": "GRANT SELECT ON `analytics`.* TO `alice`@`%`;GRANT USAGE ON *.* TO `alice`@`%`"
        }
      }
    ],
    "groups": [
      {
        "id": "app_ro@%",
        "name": "app_ro@%",
        "type": "User group",
        "description": "MySQL role",
        "created_on": "2026-07-15T00:00:00Z",
        "is_active": true,
        "members": ["alice@%"],
        "attributes": {
          "rolename": "app_ro",
          "host": "%",
          "account_locked": "Y",
          "grants": "GRANT SELECT ON `analytics`.* TO `app_ro`@`%`"
        }
      }
    ],
    "permissions": [],
    "permission_mapping": []
  },
  "metadata": {
    "resource_id": "mydb.cluster-abc.us-west-2.rds.amazonaws.com",
    "resource_type": "MySQL",
    "scan_time": "2026-07-15T00:00:00Z",
    "scan_details": "MySQL scan completed. Accounts: 1, Roles: 1",
    "scan_errors": "",
    "attribute_resolution": {
      "group_membership": "id",
      "permission_mapping": "id"
    }
  }
}
```

#### Fail-Fast Behavior

- Missing `BROKER_INJECTED_SCAN_OUTPUT_PATH` causes an immediate failure before any queries run.
- Missing tools (`mysql`, `aws`, `jq`), unreadable secret, or a failed connectivity check (`SELECT 1`) each abort the scan and write a valid error JSON so the broker always receives a parseable response.
- Credentials live only in a `chmod 600` temp defaults file, removed on exit.

#### Database Permissions Required

The admin account (from the secret) needs:

```sql
GRANT SELECT ON mysql.* TO 'scan_user'@'%';   -- mysql.user, mysql.role_edges
```

`SHOW GRANTS FOR` other accounts additionally requires `SELECT` on `mysql.*` (covered above).

#### Prerequisites

- `bash`, `mysql` client, `aws` CLI (with Secrets Manager read access), `jq`
- Network access from the broker to the endpoint on `DB_PORT`
