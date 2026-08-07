## Windows VM Scan

This directory scans a remote Windows VM for its **local** users, groups, and group memberships and outputs JSON for the Britive Resource Manager. The output schema is identical to the [Active Directory](../../Active%20Directory/scans/README.md) and [Linux](../../Linux/scans/README.md) scans so the platform stores local identities and groups per VM in the same shape.

### Scripts

| File | Runs on | Reaches the target via | Notes |
|---|---|---|---|
| `windows_scan_script.ps1` | Windows broker | PowerShell remoting (`Invoke-Command`) | Optional explicit credential; falls back to broker identity |
| `windows_scan_provision.ps1` | Windows broker | PowerShell remoting (`Invoke-Command`) | Provision credential **required** (`RESOURCE_PROVISION_*`) |
| `windows-scan.sh` | **Linux broker** | WinRM (pywinrm) or SSH (`powershell.exe -EncodedCommand`) | Shell version; same transport as the [temp-user-bridge](../permissions/temp-user-bridge/) scripts |

All three run a PowerShell enumeration on the VM (`Get-LocalUser`, `Get-LocalGroup`, `Get-LocalGroupMember`) and produce the same `data`/`metadata` schema with `resource_type = WindowsVM`.

### PowerShell: `windows_scan_provision.ps1`

Runs on a Windows broker; connects to the target over WinRM via `Invoke-Command`, enumerates local accounts **on the VM**, assembles the JSON on the broker, and writes it to the broker-specified path.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full file path where the scan JSON is written. Injected by the broker at runtime. |
| `RESOURCE_HOST` | Yes | — | Target VM hostname / IP. |
| `RESOURCE_PROVISION_USERNAME` | No | `Administrator` | WinRM admin user. |
| `RESOURCE_PROVISION_PASSWORD` | Yes | — | WinRM admin password (Basic auth). |

(The `windows_scan_script.ps1` variant instead uses `RESOURCE_TARGET` + optional `RESOURCE_BRITIVE_REMOTE_USER`/`_PASSWORD`, falling back to the broker identity when omitted.)

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

---

### Shell (Linux broker): `windows-scan.sh`

For brokers that run on Linux. Reaches the Windows target exactly like the [temp-user-bridge](../permissions/temp-user-bridge/) checkout scripts — WinRM via `python3` + `pywinrm`, or SSH via `powershell.exe -EncodedCommand`. A PowerShell block runs **on the target**, enumerates local users/groups, and emits the full Britive JSON on stdout; the broker captures it, normalizes line endings / BOM, validates it, and writes it to the output path.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full file path where the scan JSON is written. Injected by the broker. |
| `RESOURCE_HOST` | Yes | — | Target VM hostname / IP. |
| `RESOURCE_PROVISION_USERNAME` | No | `Administrator` | WinRM/SSH admin user. |
| `RESOURCE_PROVISION_PASSWORD` | Yes (winrm) | — | Admin password. Required for the `winrm` transport. |
| `PROVISION_TRANSPORT` | No | `winrm` | `winrm` or `ssh`. |
| `PROVISION_HOST` | No | `RESOURCE_HOST` | Host to connect to, if different from the target. |
| `PROVISION_PORT` | No | `5985`/`5986` (winrm), `22` (ssh) | Connection port. |
| `WINRM_NO_SSL` | No | `1` | `1` = HTTP/5985, `0` = HTTPS/5986. |
| `PROVISION_KEY` | No | `/home/bridge/.ssh/id_ed25519` | SSH private key path (ssh transport). |
| `PROVISION_KEY_PEM` | No | — | Inline PEM SSH key (preferred; written to tmpfs). |

#### Error Handling / Fast-Fail

- Fails fast on a missing output path, `RESOURCE_HOST`, an invalid `PROVISION_TRANSPORT`, missing `python3`/`pywinrm`/`ssh`, a missing winrm password, or a missing SSH key — all before connecting.
- WinRM uses bounded read/operation timeouts; SSH uses `ConnectTimeout=10` + `BatchMode=yes`.
- After the remote call: strips CRLF/BOM, then rejects **empty** output, a `PSERROR: ...` line (remote PowerShell error), or **non-JSON** output — writing a valid error JSON in each case. The final write to the broker path is verified.

#### Prerequisites

- **Broker host (Linux):** `sh`, `python3` (+ `pywinrm` for the winrm transport: `pip install pywinrm`), `ssh` (for the ssh transport), `sed`, `mktemp`; network reachability to the VM (WinRM 5985/5986 or SSH 22).
- **Target VM:** WinRM enabled with the chosen auth (NTLM/Basic; Basic over HTTP requires `AllowUnencrypted=true`), **or** Windows OpenSSH server; the admin account able to run `Get-LocalUser`/`Get-LocalGroup`/`Get-LocalGroupMember`.
