# Aurora MySQL Permissions

This directory contains Britive access broker permission scripts for Aurora MySQL. Each subdirectory implements a different access pattern via checkout/checkin script pairs.

## Access Patterns

| Directory | Pattern | Grant Scope | User Lifecycle |
| --- | --- | --- | --- |
| [`temp-user/`](temp-user/) | Temporary full-database user | `GRANT ALL ON database.*` | User created on checkout, dropped on checkin |
| [`role-member/`](role-member/) | Table-scoped privilege grant | `GRANT <privilege> ON database.table` | User created on checkout, privilege revoked on checkin |

## How It Works

Britive injects environment variables into the scripts at runtime and calls:

- **`checkout.sh` / `checkout_sql_role.sh`** — called when a user checks out a profile; provisions access
- **`checkin.sh` / `checkin_sql_role.sh`** — called when the session expires or the user checks in; revokes access

All scripts retrieve database admin credentials from AWS Secrets Manager (no secrets in environment variables or script code) and clean up temporary credential files on both success and failure.

## Choosing a Pattern

- Use **`temp-user/`** when a user needs broad access to a database (e.g., a developer running migrations or debugging).
- Use **`role-member/`** when access should be scoped to specific tables and privileges (e.g., a service account or read-only analyst).

## Common Prerequisites

Both patterns require the following on the execution host:

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

The default AWS region is `us-west-2`. Override by setting `AWS_REGION` in the environment.

## Directory Structure

```
permissions/
├── README.md               # This file
├── temp-user/
│   ├── README.md           # Full documentation for temp-user pattern
│   ├── checkout.sh         # Creates a temporary user with full database access
│   └── checkin.sh          # Drops the temporary user
└── role-member/
    ├── README.md           # Full documentation for role-member pattern
    ├── checkout_sql_role.sh  # Creates a user and grants table-scoped privileges
    └── checkin_sql_role.sh   # Revokes the granted privileges
```
