# MongoDB Atlas JIT Access — Database Roles

Grant and revoke database-level roles (e.g. `dbAdmin`, `readWrite`) on a specific database within a MongoDB Atlas project.

The database username is **derived automatically from the user's SSO email address** — no separate `db_username` variable is needed. For example, `john.doe@constoso.com` becomes `johndoe`.

## Scripts

| Script | Trigger | Action |
| ------ | ------- | ------ |
| `db-role-checkout.sh` | Profile checkout | Derives username from email; creates the DB user with a local password if they don't exist, or appends the JIT role if they do |
| `db-role-checkin.sh` | Profile checkin / timer expiry | Removes the JIT role; deletes the user entirely if they have no remaining roles (ZSP cleanup) |

## Username Derivation

The local part of the SSO email is extracted and all non-alphanumeric characters are removed:

```text
john.doe+test@corp.io     →  johndoetest
```

The derived username must be consistent between checkout and checkin — both scripts use identical derivation logic.

## New User Creation (Checkout)

If the derived username does not yet exist as a database user in Atlas, the checkout script:

1. Creates the user via `POST /databaseUsers` with a cryptographically random 24-character local password
2. Assigns only the requested JIT role
3. Prints the username and password to stdout so Britive can display them to the user

The password is shown **once** and never stored by the script. The user must save it before their session ends.

## Checkin Behaviour

| Scenario | Action |
| -------- | ------ |
| User was JIT-created (no remaining roles after revocation) | DELETE the database user entirely — no orphaned credentials |
| User pre-existed with other roles | PATCH to remove only the JIT role — baseline access is preserved |

## Authentication

Uses **MongoDB Atlas OAuth 2.0** (`client_credentials` grant) via a Service Account. Required scope: **Project Database Access Admin** or **Project Owner**.

## Database Authentication Note

MongoDB Atlas Federation (SAML/OIDC/SSO) applies only to the **Atlas control plane** (UI and API). It does **not** work for database connections. Drivers, mongosh, and other clients authenticate using:

- **SCRAM** (username/password) — used by these scripts
- **X.509** client certificates
- **AWS IAM** (AWS-hosted clusters only)
- **LDAP** — via Atlas LDAP Integration (separate Atlas configuration required)

Future migration path: configure Atlas LDAP Integration to map corporate directory users to MongoDB database access, replacing the local password created here.

## Britive Variable Configuration

Configure these variables in the Britive Resource Manager permission definition:

| Variable | Required | Description | Example |
| -------- | -------- | ----------- | ------- |
| `client_id` | Yes | OAuth2 Service Account client ID | `abc123def` |
| `client_secret` | Yes | OAuth2 Service Account client secret | (stored as secret) |
| `project_id` | Yes | Atlas project (group) ID | `6371e1e1c5a7e23b12345678` |
| `atlas_username` | Yes | Full SSO email of the requesting user | `john.doe@contoso.com` |
| `db_checkout_role` | Yes | Role to grant on checkout | `dbAdmin`, `readWrite`, `read` |
| `db_checkout_database` | Yes | Target database name | `myapp`, `admin` |

## Supported Database Roles

| Role | Scope | Use Case |
| ---- | ----- | -------- |
| `read` | Single database | Read-only access |
| `readWrite` | Single database | Application developer access |
| `dbAdmin` | Single database | Schema changes, index management |
| `dbAdminAnyDatabase` | All databases | Cross-database admin (use `admin` as db) |
| `readAnyDatabase` | All databases | Read-only across all databases |
| `readWriteAnyDatabase` | All databases | Full read/write across all databases |
| `atlasAdmin` | Cluster | Full cluster administration |

## Security Notes

- `client_secret` is passed via the HTTP Authorization header — never appears in process listings or logs.
- The generated database password is printed once to stdout and never stored.
- Concurrent Britive sessions each use an isolated `mktemp` file for API responses.
- The checkin script deletes JIT-created users rather than leaving them with zero roles — no orphaned credentials.
