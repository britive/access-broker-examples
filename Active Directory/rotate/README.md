## Active Directory Password Rotation

This directory contains PowerShell scripts used by the Britive broker to rotate passwords for Active Directory accounts as part of a checkout/checkin workflow.

### Script: `rotate-ad-account.ps1`

Resets the password for a specified AD account, unlocks it if locked, and disables the "change password at next logon" flag.

#### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `AD_TARGET_USER` | Yes | SamAccountName of the AD account to rotate (e.g., `jdoe` or `svc-app01`) |
| `AD_NEW_PASSWORD` | Yes | The new password to set on the account |

#### How It Works

1. Validates that both `AD_TARGET_USER` and `AD_NEW_PASSWORD` environment variables are set (fails immediately if not).
2. Imports the `ActiveDirectory` PowerShell module.
3. Confirms the target user exists in AD before attempting any changes.
4. Resets the account password using `Set-ADAccountPassword`.
5. Unlocks the account in case it was locked out.
6. Disables "change password at next logon" so the new credential is immediately usable.

#### Fail-Fast Behavior

- `$ErrorActionPreference = 'Stop'` promotes all non-terminating errors to terminating errors.
- Missing environment variables cause an immediate failure before any AD operations run.
- The target user is verified with `Get-ADUser` before the password reset is attempted.
- All critical AD operations use `-ErrorAction Stop` to halt on failure.

#### Security Notes

- The password is never written to stdout or logs.
- The new password is handled as a `SecureString` for the AD operation.

#### Prerequisites

- Windows PowerShell 5.1 or later
- RSAT Active Directory module installed (see [parent README](../README.md) for installation instructions)
- The broker service account must have permission to reset passwords for the target accounts

---

### Script: `rotate-ad-service-account.ps1`

Extends the basic password rotation to also update the logon credential on a Windows service running on a remote server via PSRemoting (WinRM), and optionally restarts the service so the new password takes effect immediately.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AD_TARGET_USER` | Yes | | SamAccountName of the service account (e.g., `svc-app01`) |
| `AD_NEW_PASSWORD` | Yes | | The new password to set on the account |
| `AD_TARGET_SERVER` | Yes | | Hostname or FQDN of the Windows server running the service |
| `AD_SERVICE_NAME` | Yes | | Name of the Windows service to update (e.g., `MyAppService`) |
| `AD_RESTART_SERVICE` | No | `true` | Set to `false` to skip restarting the service after credential update |

#### How It Works

1. Validates all required environment variables (fails immediately if any are missing).
2. Imports the `ActiveDirectory` PowerShell module.
3. Confirms the target user exists in AD and retrieves the domain NetBIOS name for the `DOMAIN\username` format.
4. Rotates the AD password, unlocks the account, and disables change-at-logon.
5. Connects to the remote server via `Invoke-Command` (PSRemoting/WinRM).
6. Verifies the target service exists on the remote server.
7. Updates the service logon credential using `sc.exe config`.
8. Optionally stops and restarts the service (with 60-second timeouts for each transition).
9. Verifies the service is running after restart.

#### Fail-Fast Behavior

- `$ErrorActionPreference = 'Stop'` is set both locally and inside the remote session.
- All four required environment variables are validated before any AD or remote operations run.
- The target user is verified with `Get-ADUser` before the password reset.
- The service is verified with `Get-Service` on the remote server before updating credentials.
- `sc.exe` exit code is checked explicitly — non-zero exit codes throw an error.
- Service stop/start operations have 60-second timeouts to prevent indefinite hangs.

#### Security Notes

- The password is never written to stdout or logs.
- The password is passed to the remote session via `-ArgumentList`, not embedded in the script block.

#### Prerequisites

- Windows PowerShell 5.1 or later
- RSAT Active Directory module installed (see [parent README](../README.md) for installation instructions)
- The broker service account must have permission to reset passwords for the target accounts
- WinRM/PSRemoting must be enabled on the target server
- The broker service account must have remote admin access on the target server
