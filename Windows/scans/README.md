## Windows VM Scan

This directory contains a PowerShell script that scans a remote Windows VM for its **local** users, groups, and group memberships and outputs the data as JSON for downstream processing by the Britive Resource Manager. The output schema is identical to the [Active Directory scan](../../Active%20Directory/scans/README.md) so the Britive platform stores local identities and groups per VM in the same shape.

### Script: `windows-scan.ps1`

Runs on the Britive broker. It connects to a target Windows VM over WinRM via `Invoke-Command` (the same remote pattern as the [local-admin-remote-server](../permissions/local-admin-remote-server/README.md) checkout/checkin scripts), enumerates local accounts **on the VM**, then assembles the final JSON on the broker and writes it to the broker-specified path.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full file path where the scan JSON is written. Injected by the broker at runtime. |
| `target` (or `BRITIVE_REMOTE_HOST`) | Yes | — | Target VM hostname / IP. |
| `BRITIVE_REMOTE_USER` | No | — | WinRM user. Omit to use the broker's own identity (Kerberos/integrated). |
| `BRITIVE_REMOTE_PASSWORD` | No | — | WinRM password, paired with `BRITIVE_REMOTE_USER`. |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` is set (fails immediately if not).
2. Resolves the target computer and (optionally) builds a `PSCredential`.
3. Runs the scan block on the VM via `Invoke-Command`:
   - **Users** — `Get-LocalUser`. Captures `Name`, `Enabled`, `SID`, `FullName`, `Description`.
   - **Groups** — `Get-LocalGroup` + `Get-LocalGroupMember`. Only **user** members are kept; the `COMPUTER\` / `DOMAIN\` prefix is stripped to the short account name.
4. On the broker, builds identities (with `first_name`/`last_name` parsed from `FullName`) and groups, then assembles the schema.
5. Writes the JSON to the broker-specified path.
6. On failure, writes a minimal valid JSON with the error message so the broker can report it back to the platform.

#### Identity Resolution

- **User `id`** uses the local account `Name` (e.g. `Administrator`).
- **Group `id`** uses the local group `Name`.
- **Group `members`** arrays contain user `Name` values matching identity `id` values, so `attribute_resolution.group_membership = "id"` resolves correctly.
- `SID` is stored in `attributes` for reference.

#### Output Schema

- **`data.identities`** — local users with attributes: `username`, `sid`, `first_name`, `last_name`, `full_name`, `user_desc`.
- **`data.groups`** — local groups with their user member lists and attributes: `groupname`, `sid`, `group_desc`.
- **`data.permissions`** — empty (no separate local permission objects in this model).
- **`data.permission_mapping`** — empty (user-to-group lives in `groups.members`).
- **`metadata`** — `resource_id` (VM `COMPUTERNAME`), `resource_type` = `WindowsVM`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### Fail-Fast Behavior

- `$ErrorActionPreference = 'Stop'` promotes non-terminating errors to terminating.
- Missing output path or target computer fails before any remote call.
- The top-level `try/catch` writes a valid error JSON so the broker always receives a parseable response.

#### Prerequisites

- **Broker host:** Windows PowerShell 5.1+ with WinRM client; network reachability to the VM (WinRM 5985/5986).
- **Target VM:** WinRM enabled (`Enable-PSRemoting`); the connecting account in the local Administrators group (or granted rights to `Get-LocalUser`/`Get-LocalGroup`/`Get-LocalGroupMember`); `Microsoft.PowerShell.LocalAccounts` module (built in on Windows 10/Server 2016+).
