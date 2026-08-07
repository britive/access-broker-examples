# SQL Server Scan

Enumerates SQL Server **server logins** and **server roles** and outputs JSON for
the Britive Resource Manager — the same schema used by the
[Active Directory](../../Active%20Directory/scans/README.md),
[Linux](../../Linux/scans/README.md) and
[MySQL](../../Aurora%20MySQL/scans/README.md) scans.

### Script: `mssql-scan.sh`

Runs on the Britive broker. Connects to the endpoint with admin credentials from
AWS Secrets Manager, reads the server-level catalog views, and writes the results
to the broker-supplied path. **Read only** — nothing but `SELECT`s.

#### Resource Attributes

A scan runs against a resource, and the broker injects that resource's attributes
upper-cased with a `RESOURCE_` prefix. Setting the bare name directly overrides
the attribute, so the script stays runnable by hand.

| Attribute | Arrives as | Required | Description |
|---|---|---|---|
| `DBURL` | `RESOURCE_DBURL` | Yes | SQL Server endpoint hostname |
| `AWS_SECRET_NAME` | `RESOURCE_AWS_SECRET_NAME` | Yes | Secrets Manager id holding `{username, password}` for the admin login |
| `ADMIN_USER` | `RESOURCE_ADMIN_USER` | No | Admin login; falls back to the secret's `username` field |

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full path where the scan JSON is written. Injected by the broker. |
| `DB_PORT` | No | `1433` | SQL Server port |
| `DB_NAME` | No | `master` | Database to connect to. The scan reads server-level catalog views, which live there |
| `AWS_REGION` | No | `us-west-2` | Secrets Manager region |
| `DB_CA_CERT` | No | — | CA bundle for certificate verification. Without it the connection is encrypted but the chain is **not** verified |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` (fails immediately if unset) and creates the output directory if missing.
2. Fetches admin credentials from Secrets Manager and verifies connectivity.
3. Queries `sys.server_principals` for logins (types `S`, `U`, `G`) and server roles (type `R`).
4. Queries `sys.server_role_members` for role membership.
5. Emits logins as **identities** and server roles as **groups**, with each role's members listed.
6. Writes the JSON output; on any failure writes a minimal valid JSON with the error so the broker reports it back.

#### Server level, not database level

This is a deliberate scope choice. A **login** is server-wide; a database *user*
is a per-database object mapped to a login, and there is one set of them per
database. Reporting database users would produce duplicate-looking identities
with no stable id, so the login is the identity and server roles are the groups.

#### Privileges are not enumerated

`sys.server_permissions` plus every database's object-level grants is enormous,
changes on every DDL, and Resource Manager has nothing to do with it. Server
roles are the useful unit of access.

#### Output Schema

- **`data.identities`** — one per server login, with attributes `loginname`, `type`, `is_disabled`, `create_date`, `default_database`.
- **`data.groups`** — one per server role, members listed by identity `id`.
- **`data.permissions`** — empty; permissions are defined in the resource type.
- **`data.permission_mapping`** — empty; role membership lives in `groups.members`.
- **`metadata`** — `resource_id` (the endpoint hostname), `resource_type` = `MSSQL`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### A note on the client

Uses **go-sqlcmd** (`sqlcmd`), which the `britive/bridge` image installs instead
of Microsoft's `mssql-tools` — those are glibc + amd64 only and will not run on
the musl/ARM64 image. Flags differ slightly from the Microsoft client: `-C`
trusts the server certificate, and the password comes from `SQLCMDPASSWORD`
rather than `-P` so it stays out of `/proc/<pid>/cmdline`.

#### Prerequisites

`sqlcmd` (go-sqlcmd), `aws`, `jq`, and `python3` on the broker host — all ship in
the `britive/bridge` image. Network reachability to the endpoint on `DB_PORT`.

The admin login needs `VIEW ANY DEFINITION` (or membership in a role that grants
it) to read `sys.server_principals` and `sys.server_role_members`.
