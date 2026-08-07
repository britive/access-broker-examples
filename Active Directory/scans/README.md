## Active Directory Scan

Scans Active Directory for users, groups, and group memberships and outputs JSON for the Britive Resource Manager. The output schema is identical across all scripts here (and matches the [Linux](../../Linux/scans/README.md) and [Windows](../../Windows/scans/README.md) VM scans), so the platform stores identities and groups in the same shape regardless of which script produced them.

### Scripts

| File | Runs on | Reaches AD via | Membership source |
|---|---|---|---|
| `ad-scan.ps1` | Windows broker | RSAT `ActiveDirectory` module | `Get-ADGroupMember` **per group** |
| `ad-scan_2.ps1` | Windows broker | RSAT `ActiveDirectory` module | bulk group `Member` property |
| `ad-scan.sh` | **Linux broker** | `ldapsearch` (LDAPS) | inverted from each user's `memberOf` |

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

For brokers that run on Linux (no RSAT). Binds to a Domain Controller over
**LDAPS with `ldapsearch`**; an embedded `python3` (stdlib only) parses the LDIF
and assembles the JSON. Combines the strengths of both PowerShell variants:

- **No large-group truncation** — membership is inverted from each **user's `memberOf`**, so it never hits the group-side ~5000 `MaxValRange` limit (a user is rarely in >1500 groups). Users' primary group (e.g. `Domain Users`) is excluded — the same as both PowerShell variants.
- **CNF skip + name sanitization** — replication-conflict groups are skipped; group names are stripped of newlines/tabs and truncated to 255.
- **Paged results** (default 1000/page) so directories with more than 1000 users or groups are fully enumerated.
- **Group `id` = `sAMAccountName`** (unique per domain), avoiding the display-name collision risk of the PowerShell variants.

The file is **self-contained** — one script, nothing to install alongside it. A
library-based variant that shares the LDAP plumbing with the rotation scripts
produces identical output; see [`with-library/`](with-library/) and
[`../lib/README.md`](../lib/README.md).

#### LDAPS, always

Earlier revisions defaulted to plain LDAP on port 389 with a simple bind. A DC
configured to require LDAP signing — the default on a hardened domain — rejects
that outright with `Strong(er) authentication required (8)`, so the scan could
never bind, and it sent the bind password in cleartext on the way. LDAPS is now
the only supported transport and a non-`ldaps://` URI fails up front.

#### Resource Attributes

A scan runs against a resource, and the broker injects that resource's attributes
upper-cased with a `RESOURCE_` prefix. Setting the `AD_*` name directly overrides
the attribute, so the script stays runnable by hand for testing.

| Attribute | Arrives as | Used as | Required | Description |
|---|---|---|---|---|
| `HOST` | `RESOURCE_HOST` | `AD_HOST` | Yes | Domain Controller FQDN |
| `SECRET` | `RESOURCE_SECRET` | `AD_SECRET` | Yes* | Secrets Manager id holding `{bind_dn\|username, password}` |
| `REGION` | `RESOURCE_REGION` | `AWS_REGION` | No | Secrets Manager region (default `us-west-2`) |
| `CA_CERT` | `RESOURCE_CA_CERT` | `AD_CA_CERT` | No | LDAPS trust bundle (default: system bundle) |
| `BASE_DN` | `RESOURCE_BASE_DN` | `AD_BASE_DN` | No | Search base; discovered from RootDSE when empty |
| `USER_OU` | `RESOURCE_USER_OU` | `AD_USER_OU` | No | Accepted but **not** used to scope the scan |

\* `RESOURCE_USER` and `RESOURCE_PASSWORD` are still honoured as a legacy bind
path when `SECRET` is absent. Prefer the secret: it keeps the bind password out
of the resource definition.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Full path where the scan JSON is written. Injected by the broker. |
| `AD_PORT` | No | `636` | LDAPS port |
| `AD_TLS_REQCERT` | No | `demand` | `demand` / `allow` / `never`. `never` is test-only |
| `AD_TIMEOUT` | No | `15` | LDAP network/search timeout, seconds |
| `AD_PAGE_SIZE` | No | `1000` | Paged-results page size |

#### How It Works

1. Fail-fast validation: output path, required commands present, `AD_HOST` set.
2. Reads the bind credential from Secrets Manager into a `0600` file passed with `ldapsearch -y` — never on the command line.
3. Binds over LDAPS and discovers the base DN from RootDSE (`defaultNamingContext`) unless `AD_BASE_DN` is given; this first query doubles as the bind/connectivity test.
4. Queries **users** (`(&(objectCategory=person)(objectClass=user))`) for `sAMAccountName`, `mail`, `givenName`, `sn`, `userPrincipalName`, `userAccountControl`, `memberOf`.
5. Queries **groups** (`(objectClass=group)`) for `sAMAccountName`, `cn`, `name`.
6. Builds identities (`is_active` from the `userAccountControl` `ACCOUNTDISABLE` bit; non-null `email` = `mail` or `<sam>@<domain>`), inverts `memberOf` into per-group member lists, and enumerates all groups (empty ones included).
7. Validates the assembled output is non-empty JSON, writes it, and verifies the write succeeded.
8. On any failure — bind/connect, query, parse, or write — writes a valid error JSON with the message so the broker reports it back.

#### Prerequisites

- **Broker host (Linux):** `ldapsearch` (openldap-clients), `python3`, `openssl`, `mktemp`, plus `aws` and `jq` when `AD_SECRET` is used. All ship in the `britive/bridge` image. Network reachability to the DC on LDAPS 636.
- **Directory:** the bind account able to read user and group objects.

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
