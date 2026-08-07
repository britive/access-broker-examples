## Linux VM Scan

Scans a remote Linux VM for its **local** users, groups, and group memberships
and outputs JSON for the Britive Resource Manager. The output schema matches the
[Active Directory](../../Active%20Directory/scans/README.md) scan, so the platform
stores local identities and groups per VM in the same shape.

### Script: `linux-scan.sh`

Runs on the Britive broker. SSHes into the target VM, reads the local user and
group databases with `getent`, and writes the payload to the broker-supplied
path. **Read only** — it runs `getent` and reads nothing else.

**No sudo required.** `getent` reads `/etc/passwd` and `/etc/group`, both
world-readable. Shadow entries are never touched.

#### Resource Attributes

A scan runs against a resource, and the broker injects that resource's attributes
upper-cased with a `RESOURCE_` prefix.

| Attribute | Arrives as | Required | Description |
|---|---|---|---|
| `HOSTNAME` | `RESOURCE_HOSTNAME` | Yes | Host to scan |
| `PROVISION_USER` | `RESOURCE_PROVISION_USER` | Yes | SSH login used for the scan |
| `PROVISION_KEY_LOCATION` | `RESOURCE_PROVISION_KEY_LOCATION` | No | Path to that user's private key **on the broker**. Default `/home/bridge/.ssh/id_ed25519` |

`PROVISION_KEY_LOCATION` is a **path, not key material** — the same convention
the `linux_tempuser` checkout scripts use, and it defaults to the same place: the
image writes the broker key there from Secrets Manager at startup. A Linux
resource normally leaves the attribute unset and takes the default.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full path where the scan JSON is written. Injected by the broker. |
| `SSH_PORT` | No | `22` | SSH port on the target |
| `SSH_TIMEOUT` | No | `15` | Connect timeout, seconds |
| `MIN_UID` | No | `1000` | Lowest UID reported as an identity — the conventional start of human accounts on Debian/RHEL |
| `INCLUDE_ROOT` | No | `false` | `true` to also report `root` (uid 0) |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` is set (fails immediately if not) and creates the output directory.
2. Validates the target host and that the broker SSH key exists.
3. SSHes into the VM and runs the embedded scanner.
4. **Users** — `getent passwd`, filtered by `MIN_UID`. Captures `uid`, `gid`, `first_name`/`last_name` (parsed from GECOS), `gecos`, `home`, `shell`.
5. **Groups** — `getent group`, merged with primary-group membership (see below).
6. Writes the JSON to the broker-supplied path; on failure writes a minimal valid JSON carrying the error so the broker can report it.

#### The primary-group merge

`/etc/group` lists only **secondary** members. An account's **primary** group is
a GID on its `passwd` row and appears nowhere in `/etc/group`. A scan that
reported `/etc/group` verbatim would show `developers` as empty even though every
developer has it as their login group. Both sources are combined here and the
member list is deduplicated.

#### Why system accounts are excluded

Accounts below `MIN_UID` — `daemon`, `bin`, `sshd` and friends — are not
identities anyone checks out, and importing them would put dozens of unusable
principals in the platform. Set `MIN_UID=0` with `INCLUDE_ROOT=true` if you
genuinely want everything.

#### Identity Resolution

- **User `id`** is the local username (e.g. `alice`).
- **Group `id`** is the local group name.
- **Group `members`** contain usernames matching identity `id` values, so `attribute_resolution.group_membership = "id"` resolves correctly.
- UID/GID/shell/home are kept in `attributes` for reference.

#### Output Schema

- **`data.identities`** — local users with attributes `username`, `uid`, `gid`, `first_name`, `last_name`, `gecos`, `home`, `shell`.
- **`data.groups`** — local groups with deduplicated member lists and attributes `groupname`, `gid`.
- **`data.permissions`** — empty; a POSIX account has no separate permission object.
- **`data.permission_mapping`** — empty; membership lives in `groups.members`.
- **`metadata`** — `resource_id` (the VM hostname), `resource_type` = `Linux`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### Prerequisites

**Broker host:** `bash`, `ssh`, `python3`, `mktemp`; the SSH private key readable
at `PROVISION_KEY_LOCATION` (mode `600`); network reachability to the VM on
`SSH_PORT`.

**Target VM:** SSH daemon running, and `PROVISION_USER` able to run
`getent passwd` and `getent group`.
