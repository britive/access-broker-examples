## MySQL / Aurora Account Password Rotation

Rotates the password of a MySQL / Aurora database account. The broker runs `rotate-mysql-user.sh`, which connects with **vaulted admin credentials** (AWS Secrets Manager) and runs `ALTER USER` to set the new password on the target account. It mirrors the connection contract of the [MySQL scan](../scans/README.md); the account to rotate and the new password are injected by the broker.

### Script: `rotate-mysql-user.sh`

The Britive account name is the native MySQL identity `user@host` (e.g. `readonly_user@%`). The script splits it on the **last** `@` into the user and host parts and rotates `ALTER USER 'user'@'host'`.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `RESOURCE_URL` | Yes | — | RDS / Aurora endpoint hostname. |
| `RESOURCE_AWSSECRETID` | Yes | — | Secrets Manager secret ID holding the **admin** `{username, password}` used to connect. (Mixed-case `RESOURCE_AWSsecretID` also accepted.) |
| `RESOURCE_ACCOUNT_NAME` | Yes | — | The account to rotate, as `user@host` (e.g. `readonly_user@%`). |
| `NEW_PASSWORD` | Yes | — | The new password to set on the account. |
| `RESOURCE_AWS_SECRET_REGION` | No | `us-west-2` | AWS region where the admin secret lives. |
| `DB_PORT` | No | `3306` | MySQL port on the endpoint. |
| `DB_CA_CERT` | No | — | Path to the [RDS CA bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) on the broker; enables server cert verification. Without it the connection is encrypted but the chain is not verified. |

#### How It Works

1. Validates required inputs and the `mysql`/`aws`/`jq` commands; fails fast otherwise.
2. Splits `RESOURCE_ACCOUNT_NAME` into `user`/`host` on the last `@` (defaults host to `%` if absent).
3. Fetches the admin `{username, password}` from Secrets Manager and writes a `600` `[client]` config (admin credentials never appear on the command line).
4. TLS to the endpoint: verifies against `DB_CA_CERT` when provided, otherwise stays encrypted but skips chain verification (option names differ for MariaDB vs Oracle MySQL clients).
5. Verifies the target account exists in `mysql.user`; fails if not.
6. Runs `ALTER USER 'user'@'host' IDENTIFIED BY '<new>'`. The new password is **SQL-escaped** and piped over **stdin** so it never appears in the process list or shell history, and is never logged.
7. Exits `0` on success, `1` (with a message on stderr) on any failure.

#### Prerequisites

- **Broker host:** `sh`, `mysql` client, `aws` CLI (with `secretsmanager:GetSecretValue` on the admin secret), `jq`; network reachability to the endpoint on `DB_PORT`.
- **Database:** the admin account in the secret must be able to `ALTER USER` the target account (and `SELECT` on `mysql.user` for the existence check). The RDS master user has this.

#### Notes

- Rotates an account **other than** the admin. Rotating the admin account itself would leave the Secrets Manager copy stale — manage the admin secret separately.
- `ALTER USER` only changes the password; grants/roles on the account are unchanged.
