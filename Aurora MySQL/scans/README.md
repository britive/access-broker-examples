# MySQL / Aurora MySQL Scan

Scans a MySQL or Aurora MySQL endpoint for accounts and roles and outputs JSON
for the Britive Resource Manager — the same schema used by the
[Active Directory](../../Active%20Directory/scans/README.md) and
[Linux](../../Linux/scans/README.md) scans.

### Script: `mysql-scan.sh`

Runs on the Britive broker. Connects to the endpoint with admin credentials from
AWS Secrets Manager, enumerates `mysql.user` and `mysql.role_edges`, and writes
the results to the broker-supplied path. **Read only** — nothing but `SELECT`s.

#### Resource Attributes

A scan runs against a resource, and the broker injects that resource's attributes
upper-cased with a `RESOURCE_` prefix. Setting the bare name directly overrides
the attribute, so the script stays runnable by hand for testing.

| Attribute | Arrives as | Required | Description |
|---|---|---|---|
| `DBURL` | `RESOURCE_DBURL` | Yes | RDS / Aurora endpoint hostname |
| `AWS_SECRET_NAME` | `RESOURCE_AWS_SECRET_NAME` | Yes | Secrets Manager id holding `{username, password}` for the admin account |
| `ADMIN_USER` | `RESOURCE_ADMIN_USER` | No | Admin login; falls back to the secret's `username` field |

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full path where the scan JSON is written. Injected by the broker. |
| `DB_PORT` | No | `3306` | MySQL port |
| `AWS_REGION` | No | `us-west-2` | Secrets Manager region |
| `DB_CA_CERT` | No | — | Path to the [RDS CA bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) on the broker; enables server certificate verification. Without it the connection is encrypted but the chain is not verified |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` is set (fails immediately if not) and creates the output directory if missing.
2. Fetches admin credentials from Secrets Manager and verifies connectivity.
3. Queries `mysql.user` for all accounts (`User`, `Host`, `account_locked`, `password_expired`).
4. Queries `mysql.role_edges` (MySQL 8+ / Aurora MySQL 3+) for role grants.
5. Emits accounts as **identities** and roles as **groups**, with each role's grantees as members.
6. Writes the JSON output; on any failure writes a minimal valid JSON with the error so the broker reports it back.

#### Identity is the user **and** the host

**Identity `id`** is the MySQL account identifier `user@host` (e.g. `alice@%`,
`deploy@10.0.0.5`). MySQL identity is the **pair**: `'app'@'10.0.0.1'` and
`'app'@'%'` are different accounts with different grants. Using the bare user
name as the id would merge them and hand out the wrong access.

- **Group `id`** uses the role's `user@host` identifier.
- **Group `members`** contain grantee `user@host` values matching identity `id` values, so `attribute_resolution.group_membership = "id"` resolves correctly.
- An account is classified as a **role** (group) when it appears on the `FROM` side of `mysql.role_edges`; role accounts are excluded from the identities array, and role-to-role grants are excluded from member lists.
- `is_active` is `false` when `account_locked = 'Y'`.

#### Privileges are not enumerated

A full grant dump is one row per user per database per table per column. On a
real schema that is tens of thousands of rows, it changes on every DDL, and
Resource Manager has nothing to do with it. **Roles are the useful unit of access
here.**

Pre-8.0 servers have no roles: `mysql.role_edges` does not exist, `groups` comes
back empty, and that is reported in `scan_details` rather than failing the scan.

#### Output Schema

- **`data.identities`** — all non-role MySQL accounts with attributes `username`, `host`, `account_locked`, `password_expired`.
- **`data.groups`** — MySQL roles with their grantee member lists and attributes `rolename`, `host`, `account_locked`.
- **`data.permissions`** — empty; permissions are defined in the resource type.
- **`data.permission_mapping`** — empty; role assignments live in `groups.members`.
- **`metadata`** — `resource_id` (the endpoint hostname), `resource_type` = `MySQL`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### Prerequisites

`mysql` client, `aws`, `jq`, and `python3` on the broker host — all ship in the
`britive/bridge` image. Network reachability to the endpoint on `DB_PORT`.

The admin account needs `SELECT` on `mysql.user` and `mysql.role_edges`.

#### Related

[`../rotate/rotate-mysql-user.sh`](../rotate/) rotates a discovered account's
password.
