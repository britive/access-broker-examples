# Active Directory Password Rotation

Scripts used by the **Britive Access Broker** to rotate passwords for Active
Directory accounts. Each targets a different post-rotation scenario: AD reset
alone, Windows service credential update, IIS app pool credential update, or AWS
Secrets Manager sync.

These run under Britive's **secret rotation** module — a schedule or an on-demand
rotation — rather than a profile checkout. The account is named outright in
`AD_TARGET_USER`; nothing here derives a name from the requester, and nothing
here creates an account. The target is shared infrastructure, typically a service
account.

## Pick your broker platform

| Broker runs on | Use | Reaches AD via |
|---|---|---|
| **Windows** with RSAT | the `.ps1` scripts | `ActiveDirectory` PowerShell module |
| **Linux** (the `britive/bridge` container) | the `.sh` scripts | LDAPS with `ldapsearch` / `ldapmodify` |

The two families do the same job. Variable names are shared, so a resource
configured for one works with the other.

### PowerShell — Windows broker

| Script | What it does | Extra dependencies |
|---|---|---|
| `rotate-ad-account.ps1` | Resets the AD password only | None |
| `rotate-ad-service-account.ps1` | Resets AD password + updates a Windows service on a remote server | WinRM/PSRemoting |
| `rotate-ad-iis-account.ps1` | Resets AD password + updates an IIS app pool on a remote server | WinRM/PSRemoting, WebAdministration module |
| `rotate-ad-account-aws-secret.ps1` | Resets AD password + syncs the credential to AWS Secrets Manager | AWS CLI v2 |

### Shell — Linux broker

| Script | What it does | Extra dependencies |
|---|---|---|
| `rotate-ad-account.sh` | Resets the AD password only | None |
| `rotate-ad-service-account.sh` | Resets AD password + updates a Windows service over WinRM | `pywinrm` |
| `rotate-ad-account-aws-secret.sh` | Resets AD password + patches one key of a Secrets Manager secret | `aws`, `jq` |
| `rotate-env-diagnostic.sh` | Not a rotation — dumps the environment the broker provides and exits | None |

Each `.sh` file is **self-contained**: one file, nothing to install alongside it.
A second arrangement that shares one library across all AD scripts is available
and produces identical results — see [`with-library/`](with-library/) and
[`../lib/README.md`](../lib/README.md).

There is no shell port of the IIS variant. For the two-account
"rotate one while the other is in use" pattern, see
[`Dual Account Rotation/`](Dual%20Account%20Rotation/).

All scripts share the same core flow:

1. Validate environment variables (fail-fast if missing)
2. Connect to AD (RSAT module, or an LDAPS bind)
3. Confirm the target user exists in AD
4. Reset the password
5. Unlock the account and disable "change password at next logon"
6. Perform the post-rotation action (if applicable)

Step 5 is not optional housekeeping. An administrative reset leaves the account
flagged must-change-at-next-logon, and an account in that state cannot
authenticate non-interactively — the only way a service account ever
authenticates.

---

## Britive supplies the new password

`AD_NEW_PASSWORD` is **required** by every script here, and none of them can
generate a password.

Britive's rotation module generates the value and injects it when the attribute
is configured on the rotation in the console. A password generated inside the
script would exist only in that process: the platform could neither store it nor
vend it afterwards, so the rotated credential would be lost the moment the script
exited — the account would be locked out of its own consumers with nobody holding
the new secret.

---

## Common Prerequisites

**PowerShell scripts**

- **Windows PowerShell 5.1** or later
- **RSAT Active Directory module** installed on the broker machine (see [parent README](../README.md) for installation)
- The **broker service account** must have the `Reset Password` permission on the target OU in AD

**Shell scripts**

- **LDAPS reachable on port 636.** AD refuses `unicodePwd` writes over cleartext LDAP, so port 389 cannot work
- `ldapsearch`, `ldapmodify`, `python3`, `openssl`, `base64` — all ship in the `britive/bridge` image
- A bind account with **Reset Password**, and write on `lockoutTime` and `pwdLastSet`, over the target OU
- Connection settings come from the resource — see [`../lib/README.md`](../lib/README.md) for the full `AD_*` reference

---

## Script Details

### `rotate-ad-account.ps1`

Resets the password for a specified AD account, unlocks it, and disables the "change password at next logon" flag.

#### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `AD_TARGET_USER` | Yes | SamAccountName of the AD account (e.g. `jdoe`, `svc-app01`) |
| `AD_NEW_PASSWORD` | Yes | The new password to set |

---

### `rotate-ad-service-account.ps1`

Extends the basic rotation to also update the logon credential on a **Windows service** running on a remote server via PSRemoting (WinRM), and optionally restarts the service so the new password takes effect immediately.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AD_TARGET_USER` | Yes | | SamAccountName of the service account |
| `AD_NEW_PASSWORD` | Yes | | The new password to set |
| `AD_TARGET_SERVER` | Yes | | Hostname or FQDN of the server running the service |
| `AD_SERVICE_NAME` | Yes | | Windows service name (e.g. `MyAppService`) |
| `AD_RESTART_SERVICE` | No | `true` | Set to `false` to skip restarting the service |

#### Additional Prerequisites

- WinRM/PSRemoting enabled on the target server
- Broker service account has remote admin access on the target server

---

### `rotate-ad-iis-account.ps1`

Extends the basic rotation to also update the identity credential on an **IIS Application Pool** running on a remote server via PSRemoting (WinRM), and optionally recycles the app pool.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AD_TARGET_USER` | Yes | | SamAccountName of the service account |
| `AD_NEW_PASSWORD` | Yes | | The new password to set |
| `AD_TARGET_SERVER` | Yes | | Hostname or FQDN of the IIS server |
| `AD_APPPOOL_NAME` | Yes | | IIS Application Pool name (e.g. `DefaultAppPool`) |
| `AD_RECYCLE_APPPOOL` | No | `true` | Set to `false` to skip recycling the app pool |

#### Additional Prerequisites

- WinRM/PSRemoting enabled on the target IIS server
- Broker service account has remote admin access on the target IIS server
- `WebAdministration` PowerShell module installed on the IIS server

---

### `rotate-ad-account-aws-secret.ps1`

Extends the basic rotation to also **sync the new credential to AWS Secrets Manager**. After the AD password is reset, the script fetches the existing secret JSON, patches the password field, and writes it back. All other fields in the secret (e.g. `sAMAccountName`, `host`, `port`) are preserved.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AD_TARGET_USER` | Yes | | SamAccountName of the AD account |
| `AD_NEW_PASSWORD` | Yes | | The new password to set |
| `AWS_SECRET_ARN` | Yes | | Full ARN of the Secrets Manager secret |
| `AWS_SECRET_KEY` | No | `password` | JSON key name that holds the password field in the secret |

#### Additional Prerequisites

- **AWS CLI v2** installed on the broker machine. The script resolves `aws.exe` by scanning standard install locations, so it works even when the broker service account's PATH does not include the CLI directory.
- The **EC2 instance role** (or other AWS credential source) must have the following permissions on the target secret:
  ```json
  {
      "Effect": "Allow",
      "Action": [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue"
      ],
      "Resource": "<your-secret-arn>"
  }
  ```

#### Expected Secret Format

The target secret must be a JSON string. The script reads it, updates the key specified by `AWS_SECRET_KEY` (default `password`), and writes the full object back. Example:

```json
{
    "sAMAccountName": "svc_app@ag.local",
    "password": "current-password-here"
}
```

#### Security Hardening

This script includes additional protections since it handles credentials across two systems:

| Protection | Detail |
|---|---|
| Env var cleared immediately | `AD_NEW_PASSWORD` is removed from the process environment right after being read into a variable, so child processes (including the AWS CLI) never inherit it |
| No secrets on the command line | The updated secret JSON is written to a temp file and passed via `file://` to the AWS CLI. This prevents the password from appearing in the OS process list |
| Temp file ACL-locked | The temp file is restricted to the current user only (inheritance disabled, all other ACEs removed) |
| Temp file zeroed before deletion | The file is overwritten with null bytes before being deleted, reducing the window for on-disk recovery |
| SecureString disposed | The `SecureString` holding the AD password is explicitly disposed to release protected memory |
| All variables cleaned up | A `finally` block zeros out and removes all sensitive string variables (`NewPassword`, `updatedSecret`, `getResult`) regardless of success or failure |
| UTF-8 without BOM | The temp file is written with `UTF8Encoding($false)` to avoid prepending a BOM (`EF BB BF`) which would corrupt the JSON |
| Unicode unescape | PowerShell 5.1's `ConvertTo-Json` escapes `< > & '` as `\uXXXX` sequences. The script unescapes them so the password is stored verbatim |

---

## Shell Script Details

Connection variables (`AD_HOST`, `AD_BASE_DN`, `AD_SECRET`, …) are documented in
[`../lib/README.md`](../lib/README.md) and are set on the **resource**, not per
script. The broker delivers them upper-cased with a `RESOURCE_` prefix and each
script assigns them across at the top:

| Resource attribute | Arrives as | Script reads |
|---|---|---|
| `HOST` | `RESOURCE_HOST` | `AD_HOST` |
| `BASE_DN` | `RESOURCE_BASE_DN` | `AD_BASE_DN` |
| `SECRET` | `RESOURCE_SECRET` | `AD_SECRET` |
| `REGION` | `RESOURCE_REGION` | `AWS_REGION` |
| `CA_CERT` | `RESOURCE_CA_CERT` | `AD_CA_CERT` |
| `USER_OU` | `RESOURCE_USER_OU` | `AD_USER_OU` |

`AD_TARGET_USER` and `AD_NEW_PASSWORD` need no mapping — the rotation passes its
own variables under exactly the names you configure. Setting an `AD_*` value
directly overrides the resource attribute, so every script stays runnable by hand
for testing.

Those six assignments live in each **script**, not the library, deliberately:
Britive re-fetches the script on every run, whereas a library only changes when
the broker image is rebuilt. Putting the plumbing in the script means fixing it
never needs a new image.

### Variables shared by all three rotations

| Variable | Required | Default | Description |
|---|---|---|---|
| `AD_TARGET_USER` | Yes | — | `sAMAccountName` of the account to rotate, e.g. `svc-app01`. Must already exist |
| `AD_NEW_PASSWORD` | Yes | — | The new password, injected by Britive's rotation module |
| `AD_EMIT_PASSWORD` | No | `false` | `true` prints the password on STDOUT for a response template |
| `AD_VERBOSE` | No | `false` | `true` logs progress live instead of buffering it |

---

### `rotate-ad-account.sh`

Resets the password over LDAPS, unlocks the account, and clears the
must-change-at-next-logon flag. No extra variables beyond the shared set.

The unlock is best-effort — the reset already succeeded, and failing the whole
rotation over a lockout flag would be worse than reporting it. Clearing
must-change is **not** best-effort: an account left flagged cannot authenticate
non-interactively, so the new credential would be useless.

#### Output

```
username: svc-app01
password_rotated: true
account_unlocked: true
```

---

### `rotate-ad-account-aws-secret.sh`

Resets the password in AD, then patches **one key** of an existing Secrets
Manager secret so downstream consumers pick the new value up. Every other field
in the secret (`username`, `host`, `port`, …) is preserved.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AWS_SECRET_ARN` | Yes | — | ARN (or name) of the Secrets Manager secret to patch |
| `AWS_SECRET_KEY` | No | `password` | JSON key holding the password |

#### Ordering

The secret is read and the patched JSON built **before** AD is touched, so a bad
ARN or a missing permission costs nothing. If the secret write then fails after
the reset succeeded, the script reports `DIVERGED` and names both sides — the
account has the new password, the secret still serves the old one. That is a real
break needing a manual fix and is never reported as success.

The secret must be a **JSON object**. The script refuses a plaintext secret
rather than overwriting it.

#### IAM

`secretsmanager:GetSecretValue` and `secretsmanager:PutSecretValue` on the target
secret, plus `kms:Decrypt` and `kms:GenerateDataKey` if it uses a
customer-managed key.

#### Output

Adds `secret_arn`, `secret_key` and `secret_version` to the shared output.

---

### `rotate-ad-service-account.sh`

Resets the password in AD, then writes it onto a Windows **service** logon
account over WinRM and restarts the service.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AD_TARGET_SERVER` | Yes | — | Host running the service, reachable from the broker |
| `AD_SERVICE_NAME` | Yes | — | The short Windows service name, not the DisplayName |
| `AD_RESTART_SERVICE` | No | `true` | `false` writes the credential without restarting |
| `WINRM_TRANSPORT` | No | `ntlm` | pywinrm transport |

No WinRM credential to set: the script reuses the AD bind identity from
`AD_SECRET`, which already holds domain-level rights over member servers.

#### Ordering

WinRM authentication and the service's existence are proven **first**, before AD
is touched, so an unreachable server or a typo'd service name changes nothing.
The original PowerShell had no such preflight, so exactly those mistakes produced
an outage.

If the service update fails after the reset succeeded, the service is running on
a password that no longer exists and will fail at its next restart. The script
says so explicitly rather than exiting with a bare non-zero.

#### Prerequisites

`pywinrm`, which the `britive/bridge` base image already ships. The script checks
before touching AD, so an image rebuilt from a different base fails cheaply.

**DNS matters.** The broker's VPC often does not use the domain controller for
DNS, so internal AD names may not resolve from the broker. Use the server's
private IP or a name the VPC can resolve — NTLM authenticates by name or address
alike, unlike Kerberos which would need the FQDN.

#### Output

Adds `service_updated` and `service_restarted` to the shared output.

---

### `rotate-env-diagnostic.sh`

Not a rotation. It dumps every environment variable in scope and exits, changing
nothing — no LDAP connection, no AWS call, no writes. Use it to settle what a
resource's attributes actually look like for a given action.

Wire it up as the rotation script on the resource type, run it, and read the
broker log. It works unchanged as a checkout, checkin or scan script too, so you
can compare what each action receives.

| Variable | Default | Description |
|---|---|---|
| `ENV_DUMP_FORMAT` | `json` | Or `keyvalue` for `key: value` lines a response template can render |
| `ENV_DUMP_FAIL` | `false` | `true` exits 1 after printing, forcing the text into `response.errorDetail` where it is definitely logged |
| `ENV_DUMP_REVEAL` | `false` | `true` prints credential-looking values in full. Prefer not to |

Output leads with `env_names`, `env_count` and `env_groups` **before** any
values, because Britive truncates captured output at roughly 250 characters. A
cut-off read still answers the question:

```
env_names: AD_NEW_PASSWORD,AD_TARGET_USER,RESOURCE_HOST,RESOURCE_SECRET,TRX,...
env_count: 14
env_groups: {"AD": 2, "RESOURCE": 3, "WINRM": 1, "other": 7}
RESOURCE_HOST: dc01.contoso.local
RESOURCE_SECRET: demo/ad-bind
AD_NEW_PASSWORD: <masked len=12 sha256=565dc5a2>
```

Values whose **name** looks credential-bearing (`PASSWORD`, `TOKEN`,
`PRIVATE_KEY`, `AUTH`, …) print as a length plus a SHA-256 prefix — enough to
confirm a value arrived and to tell two values apart, without putting plaintext
into a log that may be shipped elsewhere.

`*_SECRET` is shown **in full**, deliberately: here it holds a Secrets Manager
*identifier*, not a password. If your tenant puts a real password in such a
variable, add the name to `MASK_EXTRA` in the script before running it anywhere
whose logs leave your account.

---

### Reading a shell-script failure

Britive keeps roughly the **first 250 characters** of the captured output, and
CloudWatch holds nothing more — so a script that logs its progress first has its
actual error truncated away. Every shell script here therefore buffers INFO and
prints the **reason first**:

```
ERROR cannot read secret 'demo/ad-bind' in us-west-2 (check task role permissions)
trace: rotating password for account 'svc-demo-app'; reading AD bind credentials...
```

The error is always inside the window; the trace fills whatever is left. A
`set -e` abort that never reaches `die()` still reports its exit code and the
trace. `AD_VERBOSE=true` restores immediate progress logging for a hand-run.

Note that a rotation reporting `status=SUCCESS` shows **no script output at all**
in the broker request — `errorDetail` and `filename` are both empty.

---

## Troubleshooting

### "The term 'aws' is not recognized"

The broker service runs scripts under an AD service account whose `PATH` may not include the AWS CLI install directory. The `rotate-ad-account-aws-secret.ps1` script handles this automatically by scanning well-known install paths (`C:\Program Files\Amazon\AWSCLIV2\aws.exe` etc.). If the error persists, verify the CLI is installed:

```powershell
Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
```

### Secret value has `\u003c` or BOM garbage (`ï»¿`)

This was a known issue in earlier versions of the script caused by PowerShell 5.1's `ConvertTo-Json` Unicode escaping and .NET's default UTF-8 BOM encoding. The current version of `rotate-ad-account-aws-secret.ps1` handles both. If you see this on an older copy of the script, re-deploy the latest version.

### PSRemoting / WinRM connection failures

For the service account and IIS scripts that connect to remote servers:

- Verify WinRM is running on the target: `Test-WSMan -ComputerName <server>`
- Verify the broker service account is in the local Administrators group on the target server
- If using cross-domain or workgroup servers, check `TrustedHosts` configuration
- Verify no firewall rules are blocking TCP 5985 (HTTP) or 5986 (HTTPS)

### AD password changed but downstream service/app pool still uses old password

- For `rotate-ad-service-account.ps1`: ensure `AD_RESTART_SERVICE` is not set to `false`
- For `rotate-ad-iis-account.ps1`: ensure `AD_RECYCLE_APPPOOL` is not set to `false`
- If the service fails to start with the new password, verify the AD account is not locked and the password meets domain complexity requirements

### Service fails to start after rotation

If `sc.exe config` succeeded but the service won't start:

1. Check the Windows Event Log on the target server (`System` and `Application` logs)
2. Verify the service account has "Log on as a service" rights (Local Security Policy > User Rights Assignment)
3. Confirm the account is not disabled or locked in AD

---

## Fail-Fast Behavior (All Scripts)

All scripts enforce strict error handling:

- `$ErrorActionPreference = 'Stop'` promotes all non-terminating errors to terminating errors
- Required environment variables are validated before any AD or remote operations run
- The target user is verified with `Get-ADUser` before the password reset is attempted
- All critical operations use `-ErrorAction Stop` to halt on failure
- Exit code `0` on success, `1` on any failure

---

## Security Notes (All Scripts)

- Passwords are **never written to stdout or logs** -- only the username and operation status are logged
- The new password is handled as a `SecureString` for all AD operations
- For remote scripts, the password is passed via `-ArgumentList`, not embedded in the script block
