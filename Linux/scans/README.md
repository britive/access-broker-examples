## Linux VM Scan

This directory contains a POSIX shell script that scans a remote Linux VM for its **local** users, groups, and group memberships and outputs the data as JSON for downstream processing by the Britive Resource Manager. The output schema is identical to the [Active Directory scan](../../Active%20Directory/scans/README.md) so the Britive platform stores local identities and groups per VM in the same shape.

### Script: `linux-scan.sh`

Runs on the Britive broker. It SSHes into a target Linux VM (using the same connection pattern as the [temp-ssh-key-remote](../permissions/temp-ssh-key-remote/README.md) checkout/checkin scripts), runs an embedded POSIX scanner **on the VM**, captures its JSON output, and writes it to the broker-specified path. Reading `/etc/passwd` and `/etc/group` happens on the target VM via `getent`.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full file path where the scan JSON is written. Injected by the broker at runtime. |
| `RESOURCE_HOST` | Yes | — | Target server hostname / IP. Broker-injected (same as the checkout/checkin scripts). |
| `RESOURCE_USER` | No | `britivebroker` | Remote provisioning SSH user on the target. Broker-injected. |
| `RESOURCE_KEY_LOCATION` | No | `/home/britivebroker/.ssh/MYKEY.pem` | Path to the provisioning user's SSH private key. Broker-injected. |
| `SCAN_MIN_UID` | No | `0` | Lowest UID to include (e.g. `1000` to skip system accounts). |

Legacy names `BRITIVE_REMOTE_HOST`/`HOST`, `REMOTE_USER`, and `REMOTE_KEY` are still honored as fallbacks if the `RESOURCE_*` params are absent.

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` is set (fails immediately if not).
2. Validates the target host (`RESOURCE_HOST`) and the SSH key (`RESOURCE_KEY_LOCATION`) exist — fails fast before any connection.
3. SSHes into the VM (`ConnectTimeout=10`, `BatchMode=yes`) and runs the embedded scanner.
4. **Users** — `getent passwd` (filtered by `SCAN_MIN_UID`; lines with a non-numeric UID are skipped). Captures `uid`, `gid`, `first_name`/`last_name` (parsed from GECOS), `gecos`, `home`, `shell`, and a non-null `email` (`<user>@<hostid>`). `is_active` is `false` for nologin/false shells or accounts locked in `/etc/shadow` (`!`/`*`).
5. **Groups** — `getent group`. Members combine the secondary members on the group line plus users whose **primary** GID matches the group; the list is deduplicated.
6. **Validates the captured output** (non-empty and begins with `{`) before writing, and verifies the write to the broker path succeeds — so a partial/empty/unwritable result fails loudly instead of exiting `0` with bad output.
7. On any failure — SSH error, empty/non-JSON output, or write failure — writes a minimal valid JSON with the error message (and the remote stderr) so the broker reports it back to the platform.

#### Identity Resolution

- **User `id`** uses the local username (e.g. `alice`).
- **Group `id`** uses the local group name.
- **Group `members`** arrays contain usernames matching identity `id` values, so `attribute_resolution.group_membership = "id"` resolves correctly.
- SID/UID/GID/shell/home are kept in `attributes` for reference.

#### Output Schema

- **`data.identities`** — local users with attributes: `username`, `email` (`<user>@<hostid>` — the platform requires a non-null email), `uid`, `gid`, `first_name`, `last_name`, `gecos`, `home`, `shell`.
- **`data.groups`** — local groups with deduplicated member lists and attributes: `groupname`, `gid`.
- **`data.permissions`** — empty (Linux has no separate permission objects in this model).
- **`data.permission_mapping`** — empty (user-to-group lives in `groups.members`).
- **`metadata`** — `resource_id` (VM hostname), `resource_type` = `LinuxVM`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### Prerequisites

**Broker host:** `sh`, `ssh`, `mktemp`; SSH private key readable at `REMOTE_KEY` (`600`); network/SSH (port 22) reachability to the VM.

**Target VM:** SSH daemon running; the provisioning user (`RESOURCE_USER`) able to run `getent passwd`/`getent group`. Reading `/etc/shadow` (for accurate `is_active`) requires root or sudo; without it, locked-account detection degrades gracefully (accounts are reported active based on shell only).

#### Compatibility

Tested against **Ubuntu** and **Amazon Linux** (2 / 2023). The embedded scanner is POSIX `sh` only — no bashisms — so it runs identically whether the target's `/bin/sh` is dash (Ubuntu) or bash (Amazon Linux). It relies only on `getent`, coreutils (`date`, `awk`, `sed`, `cut`, `tr`, `printf`, `head`) and `hostname`; the `nologin` shell match handles both `/usr/sbin/nologin` (Ubuntu) and `/sbin/nologin` (Amazon Linux), and hostname resolution falls back to `uname -n` when the `hostname` binary is absent (e.g. Amazon Linux 2023 minimal).
