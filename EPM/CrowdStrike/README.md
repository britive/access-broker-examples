# CrowdStrike Falcon — EPM Elevation Scripts

Real Time Response (RTR) scripts that Britive invokes to grant and revoke local administrator rights on a managed workstation, just in time.

Each platform has a matched pair. Britive runs the **elevate** script when a user checks out an EPM profile, and the **de-elevate** script to revoke.

| Platform | Grant | Revoke | Language |
| --- | --- | --- | --- |
| Windows 10 / 11 | [`windows/elevate.ps1`](windows/elevate.ps1) | [`windows/de-elevate.ps1`](windows/de-elevate.ps1) | PowerShell |
| macOS | [`macos/elevate.sh`](macos/elevate.sh) | [`macos/de-elevate.sh`](macos/de-elevate.sh) | Bash |

## Prerequisites

- **Falcon Insight** or **Falcon Enterprise** licensing, with RTR support.
- **RTR Admin role on your own Falcon user account.** You cannot upload custom RTR scripts without it, and the failure comes at upload time, after everything else is configured. This is separate from the API client scopes Britive uses — granting the API client RTR Admin does not grant it to you.
- Britive EPM enabled on your tenant. It is off by default; ask your Customer Success contact.

## Uploading

Upload each script in Falcon under **Host setup and management → Response scripts and files**, as a **PowerShell** script for Windows or a **Bash** script for macOS.

> [!IMPORTANT]
> The name you upload a script under is the name Britive calls it by. Whatever you enter here must match the Grant and Revoke permission names configured on the Britive EPM profile exactly.

The `.SYNOPSIS` blocks in these scripts carry example invocations that use inconsistent cloud-file names (`win-elevation-v3`, `win-deelevation-v2`, `Mac-De-elevateUserAdminAccess`). Those are illustrative only — they are not a naming requirement. Pick one convention and use it in both Falcon and the Britive profile.

## Parameters

Every script takes exactly one parameter:

```
-Username <account>
```

Windows accepts either a bare SAM name (`jdoe`) or a qualified one (`CONTOSO\jdoe`). Unqualified names resolve as a local account first, then against the machine's AD domain. macOS expects the local short name.

> [!WARNING]
> **A UPN will not resolve.** Britive passes the value of the attribute you choose for **Account Mapping**, and that is commonly the UPN (`jdoe@contoso.com`). These scripts do not accept that form. On a domain-joined Windows machine the resolver produces `contoso.com\jdoe@contoso.com`, which fails with `ERROR: Could not resolve account`; on macOS `id jdoe@contoso.com` fails outright.
>
> Map to an attribute holding the **sAMAccountName** or local short name, or adapt the resolver in `elevate.ps1` and `de-elevate.ps1` to strip the UPN suffix.

All four scripts exit `1` with an `ERROR:` line if the parameter is missing — RTR is non-interactive and will not prompt.

## What the Windows scripts do

### `elevate.ps1`

1. Resolves the account to a SID under the SYSTEM context.
2. Adds it to the local **Administrators** group by SID. Idempotent — re-running on an already-elevated account reports and continues.
3. Verifies the membership took.
4. Resolves the user's desktop from the SID via `Win32_UserProfile`. **Fails if the user has never signed in on that machine**, because no profile exists yet.
5. Finds the interactive session (`quser`, falling back to an `explorer.exe` owner lookup) and shows a WinForms dialog plus a tray toast. Notification failures are logged but never fatal.
6. Writes two files to the user's desktop: `Run-Elevated-Installer.bat` and `ElevatedInstaller.ps1`.

**Why the desktop launcher exists.** Adding an account to Administrators does not change the token of a session that is already signed in. The user keeps their non-admin token until next logon, and UAC elevation reuses that session's linked token — so "Run as administrator" still fails right after elevation. The launcher uses `runas` to force a fresh logon that picks up the new membership, then elevates from there. Without it, the usual reaction is to tell the user to sign out and back in.

### `de-elevate.ps1`

1. Removes the account from local Administrators by SID.
2. Terminates elevated processes spawned by the elevation workflow.
3. Deletes the launcher files from the desktop.
4. Notifies the user with a dialog and tray toast.

The user is **not** logged off; the session continues with standard privileges. New elevation attempts fail because the membership is gone. It prints a summary showing what was removed, how many processes were terminated, how many files were deleted, and whether the notification was delivered.

## What the macOS scripts do

`elevate.sh` verifies the account exists, adds it to the `admin` group with `dseditgroup`, verifies membership, detects the active GUI session, and pushes an `osascript` dialog into it via `launchctl asuser`. `de-elevate.sh` is the mirror image.

Two differences from Windows worth knowing:

- **No desktop files are placed.** macOS admin group membership takes effect for `sudo` and authorization prompts without a new logon, so there is nothing equivalent to the launcher hop.
- If no active GUI session is found, both scripts still complete the group change and exit `0`, reporting `DONE (no active session)`. The privilege change is applied; only the notification is skipped.

## Reading the output

RTR returns whatever the script writes to stdout. All four use consistent prefixes, so a failed run is greppable:

| Prefix | Meaning |
| --- | --- |
| `SUCCESS:` | The group change was applied |
| `VERIFIED:` | Membership was confirmed after the change |
| `WARNING:` | Non-fatal — usually notification or session detection |
| `ERROR:` | Fatal; the script exits non-zero |

## Revocation

Under Britive, checking the profile back in runs the de-elevate script and removes the membership. That is what makes the elevation short-lived — the scripts hold no timer of their own.

If you run these scripts by hand from RTR for testing, nothing revokes for you. Run the de-elevate script when you are finished.

## Testing standalone

Before wiring up Britive, confirm the scripts work from Falcon directly. From an RTR session on a target host:

```
runscript -CloudFile="<your-uploaded-name>" -CommandLine="-Username jdoe"
```

Then verify on the host — `net localgroup Administrators` on Windows, `dseditgroup -o checkmember -m jdoe admin` on macOS — and run the de-elevate script to put it back.
