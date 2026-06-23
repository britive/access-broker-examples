## Linux VM Scan

This directory contains a POSIX shell script that scans a remote Linux VM for its **local** users, groups, and group memberships and outputs the data as JSON for downstream processing by the Britive Resource Manager. The output schema is identical to the [Active Directory scan](../../Active%20Directory/scans/README.md) so the Britive platform stores local identities and groups per VM in the same shape.

### Script: `linux-scan.sh`

Runs on the Britive broker. It SSHes into a target Linux VM (using the same connection pattern as the [temp-ssh-key-remote](../permissions/temp-ssh-key-remote/README.md) checkout/checkin scripts), runs an embedded POSIX scanner **on the VM**, captures its JSON output, and writes it to the broker-specified path. Reading `/etc/passwd` and `/etc/group` happens on the target VM via `getent`.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full file path where the scan JSON is written. Injected by the broker at runtime. |
| `BRITIVE_REMOTE_HOST` (or `HOST`) | Yes | — | Target VM hostname / IP. |
| `REMOTE_USER` | No | `britivebroker` | SSH login user on the target VM. |
| `REMOTE_KEY` | No | `/home/britivebroker/.ssh/MYKEY.pem` | Path to the broker's SSH private key. |
| `SCAN_MIN_UID` | No | `0` | Lowest UID to include (e.g. `1000` to skip system accounts). |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` is set (fails immediately if not).
2. Validates the target host and the broker SSH key exist.
3. SSHes into the VM and runs the embedded scanner.
4. **Users** — `getent passwd` (filtered by `SCAN_MIN_UID`). Captures `uid`, `gid`, `first_name`/`last_name` (parsed from GECOS), `gecos`, `home`, `shell`. `is_active` is `false` for nologin/false shells or accounts locked in `/etc/shadow` (`!`/`*`).
5. **Groups** — `getent group`. Members combine the secondary members on the group line plus users whose **primary** GID matches the group; the list is deduplicated.
6. Writes the JSON to the broker-specified path.
7. On failure, writes a minimal valid JSON with the error message so the broker can report it back to the platform.

#### Identity Resolution

- **User `id`** uses the local username (e.g. `alice`).
- **Group `id`** uses the local group name.
- **Group `members`** arrays contain usernames matching identity `id` values, so `attribute_resolution.group_membership = "id"` resolves correctly.
- SID/UID/GID/shell/home are kept in `attributes` for reference.

#### Output Schema

- **`data.identities`** — local users with attributes: `username`, `uid`, `gid`, `first_name`, `last_name`, `gecos`, `home`, `shell`.
- **`data.groups`** — local groups with deduplicated member lists and attributes: `groupname`, `gid`.
- **`data.permissions`** — empty (Linux has no separate permission objects in this model).
- **`data.permission_mapping`** — empty (user-to-group lives in `groups.members`).
- **`metadata`** — `resource_id` (VM hostname), `resource_type` = `LinuxVM`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### Prerequisites

**Broker host:** `sh`, `ssh`, `mktemp`; SSH private key readable at `REMOTE_KEY` (`600`); network/SSH (port 22) reachability to the VM.

**Target VM:** SSH daemon running; `REMOTE_USER` able to run `getent passwd`/`getent group`. Reading `/etc/shadow` (for accurate `is_active`) requires root or sudo; without it, locked-account detection degrades gracefully (accounts are reported active based on shell only).
