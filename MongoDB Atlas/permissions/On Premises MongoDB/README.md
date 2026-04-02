# MongoDB On-Premises JIT Access — Database Admin Role

Grant and revoke the `dbAdmin` role for a specific database on an on-premises MongoDB instance managed via the Atlas Administration API. Unlike the Atlas-native scripts which use OAuth2, these scripts use **Digest authentication** with a static API key pair — suitable for environments where OAuth2 Service Accounts are not available.

> **Note:** This approach replaces the user's entire role set on PATCH. The checkout sets `dbAdmin` only; the checkin restores `read` only. If the user needs multiple roles during their session, use the **DB Roles** scripts instead (which append/remove additively).

## Scripts

| Script | Trigger | Action |
|--------|---------|--------|
| `mongoDB_dbAdmin_checkout.sh` | Profile checkout | Sets the user's role to `dbAdmin` on the target database |
| `mongoDB_dbAdmin_checkin.sh` | Profile checkin / timer expiry | Restores the user's role to `read` on the target database |
| `mongoDB_dbAdmin_checkout_local_host_testing.sh` | Manual / local only | Developer testing script — not for production use |

## Authentication

Uses **MongoDB Atlas API Digest authentication** (public key / private key pair).

Required API key permissions: **Project Owner** or **Project Database Access Admin**.

## Britive Variable Configuration

Configure these variables in the Britive Resource Manager permission definition:

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `mongoDB_public_key` | Yes | Atlas API public key | `abcdefgh` |
| `mongoDB_private_key` | Yes | Atlas API private key | (stored as secret) |
| `mongoDB_project_id` | Yes | Atlas project (group) ID | `6371e1e1c5a7e23b12345678` |
| `mongoDB_username` | Yes | Full SSO email of the requesting user | `jane.doe@example.com` |
| `mongoDB_database` | No | Target database name (default: `sample_mflix`) | `myapp` |
| `mongoDB_auth_source` | No | Auth source for the database user (default: `admin`) | `admin` |

### Optional (broker host)

| Variable | Description | Default |
|----------|-------------|---------|
| `LOG_DIR` | Directory for log files | `/tmp` |

## Username Normalization

Britive passes the user's SSO email as `mongoDB_username`. The scripts strip the domain and remove non-alphanumeric characters to produce a valid MongoDB username:

```
jane.doe@example.com  →  janedoe
john+test@corp.io     →  johntest
```

The derived username must match the MongoDB Atlas database username exactly.

## Log File

Both checkout and checkin write to the same log file at `${LOG_DIR}/mongoDB_dbAdmin_checkout.log`, so the full session lifecycle (grant → revoke) is in one place.

## Local Testing

`mongoDB_dbAdmin_checkout_local_host_testing.sh` is a developer convenience script that hardcodes credentials and provides verbose output for validating the API connection before deploying scripts to the broker. Fill in the placeholder values at the top of the file before running — never commit real credentials.

## Security Notes

- `mongoDB_private_key` is passed via the `--user` flag to curl using Digest auth — never logged or echoed.
- Both scripts write to the same shared log file to make audit correlation straightforward.
- Connection is tested before any role change is attempted, so auth failures are caught early with a clear error.
- Each script uses a `mktemp` temporary file for API responses to avoid concurrent session collisions.
