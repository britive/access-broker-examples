# Aurora MySQL Temporary Read-Only User Scripts

This directory contains scripts for managing temporary **read-only** MySQL/Aurora
users through the Britive access broker, with admin credentials sourced from AWS
Secrets Manager.

## Files

- `checkout_ro.sh` - Creates (or refreshes) a read-only MySQL user and grants `SELECT, SHOW VIEW ON *.*`
- `checkin_ro.sh` - Drops the read-only user (which also removes its grants)

## How It Differs From the Other Patterns

| Pattern | Grant | User Lifecycle |
| --- | --- | --- |
| [`temp_ro/`](.) | `GRANT SELECT, SHOW VIEW ON *.*` (read-only, all DBs) | Created on checkout, dropped on checkin |
| [`temp-user/`](../temp-user/) | `GRANT ALL ON systemdb.*` (full) | Created on checkout, dropped on checkin |
| [`role-member/`](../role-member/) | `GRANT <privilege> ON db.table` (scoped) | Created on checkout, privilege revoked on checkin |

The read-only username is suffixed with `_ro` (e.g. `johndoe_ro`) to avoid
collision with a full-access user for the same person.

## Prerequisites

- Bash shell
- `mysql` client
- `aws` CLI with Secrets Manager read access
- `jq`
- `/dev/urandom` for password generation

## Environment Variables

Configured on the Britive permission and injected automatically during
checkout/checkin. All are required.

| Variable | Description | Example |
| --- | --- | --- |
| `user` | Requesting user's email (Britive auto-populates); local part is sanitized and gets a `_ro` suffix | `john.doe@company.com` → `johndoe_ro` |
| `host` | MySQL host part for `'user'@'host'` (must match between checkout/checkin) | `%` |
| `dburl` | RDS / Aurora endpoint hostname | `mydb.cluster-xyz.us-west-2.rds.amazonaws.com` |
| `secret` | AWS Secrets Manager secret ID holding admin `{username, password}` | `prod/mysql/admin` |

The AWS region is hardcoded to `us-west-2` in the scripts; edit the
`--region` flag if your resources live elsewhere.

## Usage

### Checkout (create read-only user)

```bash
export user="john.doe@company.com"
export host="%"
export dburl="mydb.cluster-xyz.us-west-2.rds.amazonaws.com"
export secret="prod/mysql/admin"

./checkout_ro.sh
```

Output is a ready-to-paste connection command:

```
mysql -hmydb.cluster-xyz.us-west-2.rds.amazonaws.com -ujohndoe_ro -p"Ax7KmP9qR2nV8sL1"
```

`checkout_ro.sh` is idempotent: `CREATE USER IF NOT EXISTS` avoids errors on
repeat checkouts, and `ALTER USER ... IDENTIFIED BY` rotates the password every
checkout so any previous session's password stops working.

### Checkin (drop read-only user)

```bash
# Same environment variables as checkout
./checkin_ro.sh
```

`DROP USER IF EXISTS` removes the user and all its grants.

## Security Notes

- Admin credentials are fetched from Secrets Manager, never stored in env vars or code.
- The admin password is passed via `MYSQL_PWD` (unset on exit via `trap`) to avoid
  `.cnf` parsing issues with special characters.
- Each checkout generates a fresh 16-character alphanumeric password.

## AWS Secrets Manager Format

```json
{
  "username": "admin",
  "password": "your-master-password"
}
```
