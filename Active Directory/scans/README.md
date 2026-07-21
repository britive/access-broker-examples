## Active Directory Scan

Scans Active Directory for users, groups, and group memberships and outputs JSON for the Britive Resource Manager. The output schema is identical across all scripts here (and matches the [Linux](../../Linux/scans/README.md) and [Windows](../../Windows/scans/README.md) VM scans), so the platform stores identities and groups in the same shape regardless of which script produced them.

### Scripts

| File | Runs on | Reaches AD via | Membership source |
|---|---|---|---|
| `ad-scan.ps1` | Windows broker | RSAT `ActiveDirectory` module | `Get-ADGroupMember` **per group** |
| `ad-scan_2.ps1` | Windows broker | RSAT `ActiveDirectory` module | bulk group `Member` property |
| `ad-scan.sh` | **Linux broker** | `ldapsearch` (LDAP) | inverted from each user's `memberOf` |

All three produce the same `data`/`metadata` schema with `resource_type = ActiveDirectory`, `id` = `SamAccountName`, and `attribute_resolution.group_membership = "id"`.

---

### PowerShell variants — `ad-scan.ps1` vs `ad-scan_2.ps1`

Both run on a **Windows broker** with the RSAT `ActiveDirectory` module. They differ only in **how group membership is retrieved**, which drives a correctness-vs-speed trade-off.

| | `ad-scan.ps1` (per-group) | `ad-scan_2.ps1` (bulk) |
|---|---|---|
| Membership | `Get-ADGroupMember` for each group | `Get-ADGroup -Properties Member`, resolved against the user set |
| Large groups (>~5000) | **Correct** — the cmdlet handles range retrieval | **Silently truncated** at AD's `MaxValRange` (~5000) |
| AD queries | One per group (**slower** with many groups) | One bulk query (**faster**) |
| CNF (replication-conflict) objects | Not filtered | **Skipped** |
| Group-name sanitization | None | Strips newlines/tabs, truncates to 255 |
| Nested / non-user members | Excluded (users only) | Excluded (only members present in the user set) |

**When to use which:**

- **`ad-scan.ps1`** — when **membership accuracy matters** and the domain has **large groups** (thousands of members). It won't truncate. Accept the extra per-group queries.
- **`ad-scan_2.ps1`** — when the domain has **many groups but each is modest in size**, and scan **speed** matters. Gets CNF handling and name sanitization, but **do not use it if any group exceeds ~5000 members** — those members are dropped without error.
- **Neither, if you can run on Linux** — prefer `ad-scan.sh` below, which avoids both weaknesses.

---

### Shell (Linux broker) — `ad-scan.sh`

For brokers that run on Linux (no RSAT). Queries a Domain Controller over **LDAP with `ldapsearch`**; an embedded `python3` (stdlib only) parses the LDIF and assembles the JSON. Combines the strengths of both PowerShell variants:

- **No large-group truncation** — membership is inverted from each **user's `memberOf`**, so it never hits the group-side ~5000 `MaxValRange` limit (a user is rarely in >1500 groups). Users' primary group (e.g. `Domain Users`) is excluded — the same as both PowerShell variants.
- **CNF skip + name sanitization** — replication-conflict groups are skipped; group names are stripped of newlines/tabs and truncated to 255.
- **Paged results** (default 1000/page) so directories with more than 1000 users or groups are fully enumerated.
- **Group `id` = `sAMAccountName`** (unique per domain), avoiding the display-name collision risk of the PowerShell variants.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full path where the scan JSON is written. Injected by the broker. |
| `RESOURCE_HOST` | Yes | — | Domain Controller hostname / IP. |
| `RESOURCE_USER` | Yes | — | Bind user (UPN `user@domain` or `DOMAIN\user`). |
| `RESOURCE_PASSWORD` | Yes | — | Bind password (passed to `ldapsearch` via a `0600` file, never on the command line). |
| `RESOURCE_BASE_DN` | No | RootDSE `defaultNamingContext` | Search base; auto-discovered from the DC if omitted. |
| `LDAP_PROTOCOL` | No | `ldap` | `ldap` or `ldaps`. |
| `LDAP_PORT` | No | `389` / `636` | Port (defaults by protocol). |
| `LDAP_START_TLS` | No | `0` | `1` to issue StartTLS on a plain `ldap` connection. |
| `PAGE_SIZE` | No | `1000` | LDAP paged-results page size. |

#### How It Works

1. Fail-fast validation: output path, `ldapsearch`/`python3` present, `RESOURCE_HOST`/`RESOURCE_USER`/`RESOURCE_PASSWORD` set.
2. Auto-discovers the base DN from RootDSE (`defaultNamingContext`) unless `RESOURCE_BASE_DN` is given — this first query also serves as the bind/connectivity test.
3. Queries **users** (`(&(objectCategory=person)(objectClass=user))`) for `sAMAccountName`, `mail`, `givenName`, `sn`, `userPrincipalName`, `userAccountControl`, `memberOf`.
4. Queries **groups** (`(objectClass=group)`) for `sAMAccountName`, `cn`, `name`.
5. Builds identities (`is_active` from the `userAccountControl` `ACCOUNTDISABLE` bit; non-null `email` = `mail` or `<sam>@<domain>`), inverts `memberOf` into per-group member lists, and enumerates all groups (empty ones included).
6. Validates the assembled output is non-empty JSON, then writes it; verifies the write succeeds.
7. On any failure — bind/connect, query, parse, or write — writes a valid error JSON with the message so the broker reports it back.

#### Prerequisites

- **Broker host (Linux):** `sh`, `ldapsearch` (openldap-clients), `python3`, `sed`, `mktemp`; network reachability to the DC (LDAP 389 / LDAPS 636).
- **Directory:** the bind account able to read user and group objects. Plain `ldap` sends the bind password in cleartext — prefer `ldaps` or `LDAP_START_TLS=1` in production.

---

### Shared: Identity Resolution & Output Schema

- **User `id`** = `SamAccountName` (short, fits `native_id` limits). **Group `id`** = the group name (PowerShell variants) or `sAMAccountName` (shell).
- **Group `members`** contain user `SamAccountName` values matching identity `id`s, so `attribute_resolution.group_membership = "id"` resolves.
- **`data.identities`** — users with attributes: `email` (non-null), `first_name`, `last_name`, `samaccountname`, `user_principal_name`, `distinguished_name`.
- **`data.groups`** — groups with user member lists and attributes: `samaccountname`, `distinguished_name`.
- **`data.permissions`** / **`data.permission_mapping`** — empty (AD has no separate permission objects; user-to-group lives in `groups.members`).
- **`metadata`** — `resource_id` (domain/base DN), `resource_type` = `ActiveDirectory`, `scan_time`, `scan_details`, `scan_errors`, `attribute_resolution`.

#### Fail-Fast (all scripts)

- PowerShell: `$ErrorActionPreference = 'Stop'`; missing output path or AD module fails before scanning; top-level `try/catch` writes a valid error JSON.
- Shell: validates commands + inputs before binding; the RootDSE query doubles as the bind test; empty/non-JSON output and write failures each produce a valid error JSON.
