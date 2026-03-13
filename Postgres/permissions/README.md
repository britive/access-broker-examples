# PostgreSQL Access Patterns

This directory contains three just-in-time access patterns for PostgreSQL, each targeting a different privilege level and use case. All patterns are designed to integrate with the Britive platform's checkout/checkin flow.

## Access Pattern Comparison

| Feature | [`role-grant`](#role-grant) | [`dba-access`](#dba-access) | [`superuser`](#superuser) |
| --- | --- | --- | --- |
| **Privilege level** | Fine-grained (specific role) | High (monitoring + DBA ops) | Highest (full server admin) |
| **Creates a new user** | No | Yes | Yes |
| **Credential management** | Env vars | AWS Secrets Manager | Env vars |
| **External dependencies** | `psql` only | AWS CLI, `jq`, `openssl` | `psql`, `tr` |
| **Use for data access** | Yes (role-defined) | No (management only) | Yes (unrestricted) |

## Folders

### `role-grant`

**Grant or revoke a pre-defined role to an existing database user.**

Use this pattern for routine data access — analysts, application accounts, reporting users, etc. The PostgreSQL user must already exist; only the role membership changes.

- **Checkout**: `GRANT <role> TO <user>`
- **Checkin**: `REVOKE <role> FROM <user>`
- **Env vars**: `BRITIVE_USER`, `svc_user`, `svc_password`, `db_host`, `db_name`, `role_name`
- **Service account needs**: `ADMIN OPTION` on each managed role

See [role-grant/README.md](role-grant/README.md) for full details.

---

### `dba-access`

**Create a temporary user with monitoring and DBA-level management privileges.**

Use this pattern when an operator needs to inspect server internals, terminate sessions, or manage schemas — without full superuser access. Service account credentials are stored in **AWS Secrets Manager** rather than passed as environment variables.

Privileges granted: `ALL PRIVILEGES ON DATABASE`, `pg_monitor`, `pg_signal_backend`.

- **Checkout**: `grant_dba_access.sh` — creates user, outputs pgAdmin/DBeaver connection JSON
- **Checkin**: `revoke_dba_access.sh` — removes user and all its privileges
- **Env vars**: `BRITIVE_USER`, `SECRET_NAME`, `DB_NAME`
- **Service account needs**: `CREATEROLE`, `GRANT OPTION` on delegated privileges

Also includes `aws_sample_db.yml` — a CloudFormation template to provision a sample RDS PostgreSQL instance for testing.

See [dba-access/README.md](dba-access/README.md) for full details.

---

### `superuser`

**Create a temporary user with full PostgreSQL SUPERUSER privileges.**

Use this pattern only when the highest level of access is genuinely required — emergency break-glass access, major migrations, or root-cause investigations that cannot be performed with narrower privileges. Requires an approval workflow in Britive.

- **Checkout**: `postgres-adminaccess-checkout.sh` — creates SUPERUSER, outputs connection command
- **Checkin**: `postgres-adminaccess-checkin.sh` — removes user and all its privileges
- **Env vars**: `BRITIVE_USER`, `svc_user`, `svc_password`, `db_host`, `db_name`
- **Service account needs**: must itself be a `SUPERUSER`

See [superuser/README.md](superuser/README.md) for full details.

---

## Common Design Decisions

### `BRITIVE_USER`

All scripts read the requesting user's identity from the `BRITIVE_USER` environment variable, which is automatically set by the Britive platform when a checkout/checkin script is executed.

### Username derivation

The PostgreSQL username is derived from the email local-part. Non-alphanumeric characters are either replaced with underscores (`dba-access`) or stripped entirely (`superuser`, `role-grant`):

| Email | `dba-access` username | `superuser` / `role-grant` username |
| --- | --- | --- |
| `john.doe@company.com` | `john_doe` | `johndoe` |
| `jane-smith@company.com` | `jane_smith` | `janesmith` |

### Owned object cleanup

All user-creating scripts (`dba-access`, `superuser`) use `REASSIGN OWNED BY … TO <svc_user>` followed by `DROP OWNED BY` before dropping the role. This prevents `DROP ROLE` from failing when the temporary user created schemas, tables, or sequences during their session.

### Port

All scripts connect on the default PostgreSQL port **5432**. If your instance uses a different port, update the `-p` flag in the psql calls.
