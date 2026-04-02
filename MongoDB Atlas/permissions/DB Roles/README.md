# MongoDB Atlas JIT Access — Database Roles

Grant and revoke database-level roles (e.g. `dbAdmin`, `readWrite`) on a specific database within a MongoDB Atlas project. Roles are **additive** — the JIT role is appended to the user's existing roles on checkout, and only the JIT role is removed on checkin, leaving any other roles untouched.

## Scripts

| Script | Trigger | Action |
|--------|---------|--------|
| `db-role-checkout.sh` | Profile checkout | Appends `{{db_checkout_role}}` on `{{db_checkout_database}}` to the user |
| `db-role-checkin.sh` | Profile checkin / timer expiry | Removes `{{db_checkout_role}}` on `{{db_checkout_database}}` from the user |

## Authentication

Uses **MongoDB Atlas OAuth 2.0** (`client_credentials` grant) via a Service Account. This is the recommended approach for automated integrations — tokens are short-lived and scoped to the Service Account's permissions.

Required Service Account scope: **Project Database Access Admin** or **Project Owner**.

## Britive Variable Configuration

Configure these variables in the Britive Resource Manager permission definition:

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `client_id` | Yes | OAuth2 Service Account client ID | `abc123def` |
| `client_secret` | Yes | OAuth2 Service Account client secret | (stored as secret) |
| `project_id` | Yes | Atlas project (group) ID | `6371e1e1c5a7e23b12345678` |
| `db_username` | Yes | Atlas database username to elevate | `janesmith` |
| `db_checkout_role` | Yes | Role to grant on checkout | `dbAdmin`, `readWrite`, `read` |
| `db_checkout_database` | Yes | Target database name | `myapp`, `admin` |

## Supported Database Roles

Any valid MongoDB database role can be used. Common examples:

| Role | Scope | Use Case |
|------|-------|----------|
| `read` | Single database | Read-only access |
| `readWrite` | Single database | Application developer access |
| `dbAdmin` | Single database | Schema changes, index management |
| `dbAdminAnyDatabase` | All databases | Cross-database admin (use `admin` as db) |
| `readAnyDatabase` | All databases | Read-only across all databases |
| `readWriteAnyDatabase` | All databases | Full read/write across all databases |
| `atlasAdmin` | Cluster | Full cluster administration |

## Security Notes

- `client_secret` is passed via the HTTP Authorization header — never appears in process listings or logs.
- Concurrent Britive sessions each use an isolated `mktemp` file for API responses — no race conditions.
- Checkout is **additive**: existing roles are preserved and the JIT role is appended. Checkin removes only the exact `(roleName, databaseName)` pair that was granted.
- Token lifetime is controlled by Atlas (typically 60 seconds). Scripts obtain a fresh token on every execution.
