## MySQL / Aurora DB Scan

This directory contains a POSIX shell script that scans a **MySQL / Aurora RDS instance** for its database accounts (users) and roles (and the role→user assignments), and outputs the data as JSON for the Britive Resource Manager. The output schema matches the [Linux](../../Linux/scans/README.md) and [Windows](../../Windows/scans/README.md) VM scans so local database identities and roles are stored per instance in the same shape.

### Script: `mysql-scan.sh`

Runs on the Britive broker. It reads vaulted admin credentials from AWS Secrets Manager (the same pattern as the [temp-user](../permissions/temp-user/README.md) checkout scripts), connects to the RDS/Aurora endpoint with the `mysql` client, and enumerates:

- **Identities** — login accounts from `mysql.user`.
- **Groups** — MySQL **roles**, with members (grantees) from `mysql.role_edges`.
- **Permissions** — left empty (defined in the resource type, matching the other scans).

JSON is assembled with `jq` for safe escaping.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full file path where the scan JSON is written. Injected by the broker at runtime. |
| `RESOURCE_URL` | Yes | — | RDS / Aurora endpoint hostname. Broker-injected resource param. |
| `RESOURCE_AWSSECRETID` | Yes | — | Secrets Manager secret ID holding admin `{username, password}`. Broker-injected. (The mixed-case form `RESOURCE_AWSsecretID` is also accepted.) |
| `RESOURCE_AWS_SECRET_REGION` | No | `us-west-2` | AWS region where the secret lives. Broker-injected. |
| `DB_PORT` | No | `3306` | MySQL port on the endpoint. |
| `DB_CA_CERT` | No | — | Path to the [RDS CA bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) on the broker; enables server cert verification. Without it the connection is encrypted but the chain is not verified. |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH`, `RESOURCE_URL`, `RESOURCE_AWSSECRETID`, and the `mysql`/`aws`/`jq` commands.
2. Fetches admin `{username, password}` from Secrets Manager and writes a `600` `[client]` config (credentials never appear on the command line).
3. TLS to the endpoint: verifies against `DB_CA_CERT` when provided, otherwise stays encrypted but skips chain verification (option names differ for MariaDB vs Oracle MySQL clients).
4. **Users** — `SELECT User, Host, account_locked, password_expired, plugin FROM mysql.user`. `is_active` is `false` when `account_locked = 'Y'`.
5. **Roles** — `SELECT FROM_USER, FROM_HOST, TO_USER, TO_HOST FROM mysql.role_edges`. An account that is granted to others (appears as `FROM`) is treated as a role; members are the `TO` grantees. `role_edges` only exists on MySQL 8.0+; on 5.7 the query degrades to "no roles".
6. Writes the JSON to the broker-specified path.
7. On any failure, writes a minimal valid JSON with the error message so the broker can report it back.

#### Identity Resolution

- **User `id`** and **role `id`** use `user@host` (e.g. `alice@%`) — the real MySQL account identity, since the same username can exist for multiple hosts.
- **Role `members`** arrays contain `user@host` values matching identity `id`s, so `attribute_resolution.group_membership = "id"` resolves correctly.
- Host, `account_locked`, `password_expired`, and `auth_plugin` are kept in `attributes` for reference.

#### Output Schema

- **`data.identities`** — database users with attributes: `username`, `email` (`<user>@<endpoint>` — the platform requires a non-null email), `host`, `account_locked`, `password_expired`, `auth_plugin`.
- **`data.groups`** — MySQL roles with member lists and attributes: `rolename`, `host`.
- **`data.permissions`** — empty (permissions are defined in the resource type).
- **`data.permission_mapping`** — empty (role-to-user lives in `groups.members`).
- **`metadata`** — `resource_id` (endpoint), `resource_type` = `MySQLDB`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### Prerequisites

**Broker host:** `sh`, `mysql` client, `aws` CLI (with `secretsmanager:GetSecretValue` on the secret), `jq`, `mktemp`; network reachability to the RDS/Aurora endpoint on `DB_PORT`.

**Database:** the admin account in the secret must have `SELECT` on `mysql.user` and `mysql.role_edges`. The RDS master user has this by default.

#### Limitations

- A role with **no grantees** is indistinguishable from a user (MySQL has no authoritative "is role" column) and is reported as a user.
- Direct object privileges (`GRANT`s) are not enumerated — the scan captures identities, roles, and role membership only.
