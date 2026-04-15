# Active Directory Password Rotation

This directory contains PowerShell scripts used by the **Britive Access Broker** to rotate passwords for Active Directory accounts as part of a checkout/checkin workflow. Each script targets a different post-rotation scenario: standalone AD reset, Windows service credential update, IIS app pool credential update, or AWS Secrets Manager sync.

## Scripts at a Glance

| Script | What it does | Extra dependencies |
|---|---|---|
| `rotate-ad-account.ps1` | Resets the AD password only | None |
| `rotate-ad-service-account.ps1` | Resets AD password + updates a Windows service on a remote server | WinRM/PSRemoting |
| `rotate-ad-iis-account.ps1` | Resets AD password + updates an IIS app pool on a remote server | WinRM/PSRemoting, WebAdministration module |
| `rotate-ad-account-aws-secret.ps1` | Resets AD password + syncs the credential to AWS Secrets Manager | AWS CLI v2 |

All scripts share the same core flow:

1. Validate environment variables (fail-fast if missing)
2. Import the `ActiveDirectory` PowerShell module
3. Confirm the target user exists in AD
4. Reset the password via `Set-ADAccountPassword`
5. Unlock the account and disable "change password at next logon"
6. Perform the post-rotation action (if applicable)

---

## Common Prerequisites

- **Windows PowerShell 5.1** or later
- **RSAT Active Directory module** installed on the broker machine (see [parent README](../README.md) for installation)
- The **broker service account** must have the `Reset Password` permission on the target OU in AD

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
