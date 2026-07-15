# Aurora MySQL Permissions

This directory contains Britive access broker permission scripts for Aurora MySQL. Each subdirectory implements a different access pattern via checkout/checkin script pairs.

## Access Patterns

| Directory | Pattern | Grant Scope | User Lifecycle |
| --- | --- | --- | --- |
| [`temp-user/`](temp-user/) | Temporary full-database user | `GRANT ALL ON systemdb.*` | User created on checkout, dropped on checkin |
| [`temp_ro/`](temp_ro/) | Temporary read-only user | `GRANT SELECT, SHOW VIEW ON *.*` | User created on checkout, dropped on checkin |
| [`role-member/`](role-member/) | Table-scoped privilege grant | `GRANT <privilege> ON database.table` | User created on checkout, privilege revoked on checkin |
| [`temp-user-bridge/`](temp-user-bridge/) | Temporary user, proxied via Britive Bridge | `GRANT ALL ON <DB_NAME>.*` | User created on checkout, dropped on checkin; session brokered + recorded by the Bridge |

## How It Works

Britive injects environment variables into the scripts at runtime and calls:

- **`checkout*.sh`** — called when a user checks out a profile; provisions access
- **`checkin*.sh`** — called when the session expires or the user checks in; revokes access

All scripts retrieve database admin credentials from AWS Secrets Manager (no secrets in environment variables or script code) and clean up temporary credential files on both success and failure.

## Choosing a Pattern

- Use **`temp-user/`** when a user needs broad access to a single database (e.g., a developer running migrations or debugging).
- Use **`temp_ro/`** when a user needs read-only visibility across all databases (e.g., an analyst or on-call responder inspecting data).
- Use **`role-member/`** when access should be scoped to specific tables and privileges (e.g., a service account or narrow report).
- Use **`temp-user-bridge/`** when sessions must be brokered and recorded — the user connects their local `mysql` client to the Britive Bridge proxy with a per-checkout Bridge password and never holds the real database credentials.

## Common Prerequisites

All patterns require the following on the execution host:

- `bash`
- `mysql` client
- `aws` CLI with Secrets Manager read access
- `jq`

The AWS Secrets Manager secret must contain a JSON object with `username` and `password` fields:

```json
{
  "username": "admin",
  "password": "your-master-password"
}
```

The default AWS region is `us-west-2`. `role-member/` reads it from the `AWS_REGION`
environment variable (defaulting to `us-west-2`); `temp-user/` and `temp_ro/` hardcode
`--region us-west-2` — edit the `--region` flag in those scripts to change it.

## Directory Structure

```
permissions/
├── README.md               # This file
├── temp-user/
│   ├── README.md           # Full documentation for temp-user pattern
│   ├── checkout.sh         # Creates a temporary user with full access to systemdb
│   └── checkin.sh          # Drops the temporary user
├── temp_ro/
│   ├── README.md           # Full documentation for temp_ro pattern
│   ├── checkout_ro.sh      # Creates a read-only user (SELECT, SHOW VIEW on *.*)
│   └── checkin_ro.sh       # Drops the read-only user
├── role-member/
│   ├── README.md           # Full documentation for role-member pattern
│   ├── checkout_sql_role.sh  # Creates a user and grants table-scoped privileges
│   └── checkin_sql_role.sh   # Revokes the granted privileges
└── temp-user-bridge/
    ├── README.md                  # Full documentation for the Bridge-proxied pattern
    ├── checkout_mysql_bridge.sh   # Creates a temp user + registers a Bridge mysql checkout
    └── checkin_mysql_bridge.sh    # Drops the temp user + deletes the Bridge checkout
```
