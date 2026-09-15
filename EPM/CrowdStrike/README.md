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

The usage strings inside the scripts say `-CloudFile="<uploaded-name>"` rather than a literal name. Pick one convention and use it in both Falcon and the Britive profile.

## Parameters

Every script takes exactly one parameter:

```
-Username <account>
```

Windows accepts either a bare SAM name (`jdoe`) or a qualified one (`CONTOSO\jdoe`). Unqualified names resolve as a local account first, then against the machine's AD domain. macOS expects the local short name.

> [!WARNING]
> **A UPN will not resolve.** Britive passes the value of the attribute you choose for **Account Mapping**, and that is commonly the UPN (`jdoe@contoso.com`). These scripts do not accept that form. On a domain-joined Windows machine the resolver produces `contoso.com\jdoe@contoso.com`, which fails with `code: RESOLVE_FAILED`; on macOS `id jdoe@contoso.com` fails outright and the elevate script reports `code: USER_NOT_FOUND`.
>
> Map to an attribute holding the **sAMAccountName** or local short name, or adapt the resolver in `elevate.ps1` and `de-elevate.ps1` to strip the UPN suffix.

All four scripts report `MISSING_PARAM` if the parameter is missing — RTR is non-interactive and will not prompt.

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

Three differences from Windows worth knowing:

- **No desktop files are placed.** macOS admin group membership takes effect for `sudo` and authorization prompts without a new logon, so there is nothing equivalent to the launcher hop.
- **A missing account is fatal on elevate, not on de-elevate.** `de-elevate.sh` still runs the `dseditgroup` membership check for an account that `id` cannot find, and reports `NOT_MEMBER` success once that check confirms no admin rights are held.
- If no active GUI session is found, both scripts still complete the group change and report `status: success` with a `notify_no_session` warning. The privilege change is applied; only the notification is skipped.

## Reading the output

### Why the exit code is useless

RTR reports whether the command was **delivered and run**, not what the script concluded. A `runscript` invocation comes back successful whenever Falcon managed to execute it, and the script's own exit code is not carried in the admin-command response at all. `exit 1` inside a cloud script terminates the script and changes nothing about what the caller sees.

So the outcome has to travel in the script's stdout.

### The `BRITIVE_STATUS` marker

Every one of the four scripts ends by writing a single line to stdout:

```
BRITIVE_STATUS {"status":"success","action":"elevate","code":"OK","user":"CONTOSO\\jdoe","host":"WKS-01","message":"...","warnings":["notify_no_session"]}
```

Fields:

| Field | Meaning |
| --- | --- |
| `status` | `success` or `error`. The only field a caller must branch on. |
| `action` | `elevate` or `de-elevate`. |
| `code` | Machine-readable reason. See the table below. |
| `user` | The account as the script resolved it — qualified (`DOMAIN\user`) on Windows. |
| `host` | The machine the script ran on. |
| `message` | Human-readable detail, truncated to 300 characters. |
| `warnings` | Non-fatal problems. Never affects `status`. |

**Parsing rules, in order:**

1. Take the **last** line of stdout matching `^BRITIVE_STATUS `, strip that prefix, parse the remainder as JSON.
2. If no such line exists, treat the run as an **error**. A missing marker means the script was killed, timed out, or its output was truncated — never that it succeeded.
3. Branch on `status`. Use `code` for specific handling; do not parse `message`.

Rule 2 is the important one. The marker is written on every path the scripts can take, including unhandled failures: the Bash scripts arm an `EXIT` trap with a pessimistic default before doing any work, and the PowerShell scripts install a script-scope `trap` alongside the same default. If the marker is absent, something killed the script from outside.

### Codes

| `code` | `status` | Meaning |
| --- | --- | --- |
| `OK` | success | The group change was applied and verified. |
| `NOT_MEMBER` | success | De-elevate only. The account already held no admin rights; verified. |
| `MISSING_PARAM` | error | No `-Username` supplied. |
| `NOT_PRIVILEGED` | error | macOS only. Not running as root. |
| `USER_NOT_FOUND` | error | Elevate only. The account does not exist on the host. |
| `RESOLVE_FAILED` | error | Windows only. The name would not resolve to a SID. |
| `GROUP_ADD_FAILED` | error | The membership change was rejected. |
| `GROUP_REMOVE_FAILED` | error | De-elevate only. The removal was rejected. |
| `VERIFY_FAILED` | error | The membership could not be confirmed after the change. |
| `NO_USER_PROFILE` | error | Windows elevate only. No desktop folder — the user has never signed in. |
| `DESKTOP_WRITE_FAILED` | error | Windows elevate only. The launcher files could not be written. |
| `UNEXPECTED` | error | An unhandled error. `message` carries the exception text. |

### Warnings

`warnings` records what degraded without changing the outcome. The privilege change is the deliverable; the notification and the cleanup are not.

`notify_no_session`, `notify_failed`, `notify_dialog_failed`, `notify_toast_failed`, `session_lookup_failed`, `profile_lookup_failed`, `verify_failed_soft`, `process_terminate_partial`, `file_delete_partial`, `desktop_not_found`, `user_not_found`.

### Two error cases that leave the host elevated

`NO_USER_PROFILE` and `DESKTOP_WRITE_FAILED` are raised by `elevate.ps1` **after** the account has already been added to Administrators. The scripts do not roll that back, and say so in `message`. A caller that treats these as a failed checkout should run the de-elevate script to clean up.

### Human-readable prefixes

The chatty output above the marker still uses consistent prefixes, useful when reading a run by hand:

| Prefix | Meaning |
| --- | --- |
| `SUCCESS:` | The group change was applied |
| `VERIFIED:` | Membership was confirmed after the change |
| `WARNING:` | Non-fatal — usually notification or session detection |
| `ERROR:` | Fatal; a `BRITIVE_STATUS` error marker follows |

Do not parse these. They are for people; `BRITIVE_STATUS` is for machines.

## Revocation

Under Britive, checking the profile back in runs the de-elevate script and removes the membership. That is what makes the elevation short-lived — the scripts hold no timer of their own.

If you run these scripts by hand from RTR for testing, nothing revokes for you. Run the de-elevate script when you are finished.

## Testing standalone

Before wiring up Britive, confirm the scripts work from Falcon directly. From an RTR session on a target host:

```
runscript -CloudFile="<your-uploaded-name>" -CommandLine="-Username jdoe"
```

Read the last line of the returned stdout — it is the `BRITIVE_STATUS` marker, and it is the only part that tells you whether the run worked. The RTR command itself reports success either way.

Then verify on the host — `net localgroup Administrators` on Windows, `dseditgroup -o checkmember -m jdoe admin` on macOS — and run the de-elevate script to put it back.

To test the failure contract, invoke a script with no `-CommandLine` at all and confirm you get back:

```
BRITIVE_STATUS {"status":"error","action":"elevate","code":"MISSING_PARAM",...}
```
