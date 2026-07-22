# Dual Account Rotation Demo

This directory demonstrates **dual-account credential rotation** for an Active
Directory service identity, fronted by the **Britive Vault**. It shows how a
consumer can always fetch the currently-**active** credential without ever
knowing which of the two backing accounts is live.

## Why Dual-Account?

A single service account has a hard problem: the moment you rotate its password,
every consumer still holding the old password fails to authenticate until it
re-fetches. There is an unavoidable outage window.

Dual-account rotation removes that window. Two functionally identical accounts
(`A` and `B`) share the same group membership and permissions. Only one is
**active** at a time:

1. `A` is active. Consumers authenticate with `A`.
2. Rotation flips the active pointer to `B` (whose password is already valid).
3. `A`'s password is then rotated in the background — no consumer was using it.
4. Next rotation flips back to `A`, and so on.

The Britive dual-account secret always returns the **active** side, so the
consumer just asks the vault "give me the current credential" and never sees a
failed bind.

## Contents

| File | Purpose |
|---|---|
| `ad_setup.ps1` | One-time AD setup: creates the demo OU, shared group, and the two service accounts (`A`/`B`) that Britive will rotate. |
| `Get-ActiveCred.ps1` | Function that returns the currently-active credential from the Britive dual-account secret (or a local file in simulate mode). |
| `Watch-DualAuth.ps1` | Live auth timeline. Binds to AD on a loop and prints SUCCESS/FAIL so you can watch a rotation happen without an outage. |

## Prerequisites

- **Windows PowerShell 5.1** or later
- **RSAT Active Directory module** (`Import-Module ActiveDirectory`)
- Rights to create OUs, groups, and users in the target domain (for `ad_setup.ps1`)
- **pybritive** CLI installed and authenticated (for live, non-simulate mode)
- A Britive **dual-account secret** configured to return the active credential

> The scripts default to a placeholder domain `example.local` /
> `DC=example,DC=local`. Override with parameters (see Setup) to match your
> directory. **Do not commit real domain, tenant, or credential values.**

## Setup

### 1. Create the AD objects

```powershell
.\ad_setup.ps1 `
    -Domain    "corp.example.local" `
    -OU        "OU=ServiceAccounts,DC=corp,DC=example,DC=local" `
    -OUName    "ServiceAccounts" `
    -OUPath    "DC=corp,DC=example,DC=local" `
    -GroupName "svc-webapp" `
    -AccountA  "svc-webapp-a" `
    -AccountB  "svc-webapp-b"
```

The script prompts for the initial password (never hardcoded) and is safe to
re-run — existing OU/group/accounts are skipped.

### 2. Configure the Britive dual-account secret

Create a static-secret template with `account` and `password` fields and register
both AD accounts for dual-account rotation. Point `Get-ActiveCred.ps1`'s
`-SecretPath` at the secret (default: `/IT Secrets/WebApp Dual Account`). Adjust
the field-name mapping in `Get-ActiveCred.ps1` if your template uses different
keys.

### 3. Run the live watcher

```powershell
# Live: pulls the active credential from Britive every 3s
.\Watch-DualAuth.ps1 -Domain "corp.example.local"

# Baseline (the "before" case): pin one account and watch it break on rotation
.\Watch-DualAuth.ps1 -Static svc-webapp-a -Domain "corp.example.local"
```

### Rehearse without a tenant (Simulate)

You can rehearse the whole demo with no Britive tenant using a local file:

```powershell
# active.txt contains a single line: username|password
"svc-webapp-a|CurrentP@ss" | Set-Content .\active.txt

.\Watch-DualAuth.ps1 -Simulate -Domain "corp.example.local"
```

Edit `active.txt` by hand (flip to `svc-webapp-b|...`) to fake a rotation and
watch the timeline follow the active side.

## Fail-Fast & Error Handling

All scripts set `$ErrorActionPreference = 'Stop'` and validate inputs before
performing any AD or vault operation:

- **`ad_setup.ps1`** — imports the AD module, prompts for the initial password,
  and skips objects that already exist. Any failure exits `1` with a clear
  message; success exits `0`.
- **`Get-ActiveCred.ps1`** — validates the simulate file exists and is well-formed,
  checks `pybritive` is on PATH, inspects the CLI exit code, parses JSON
  defensively, and confirms the expected secret fields are present. Throws a
  descriptive error otherwise.
- **`Watch-DualAuth.ps1`** — fails fast at startup if the helper is missing or the
  domain context cannot be built. The watch loop itself is intentionally
  resilient: a transient per-tick error is logged and the timeline keeps ticking
  through a rotation.

## Security Notes

- Passwords are **never printed** — the watcher masks all but the last two
  characters.
- The initial password in `ad_setup.ps1` is **prompted**, never hardcoded.
- Britive owns rotation after setup; the AD accounts' `PasswordNeverExpires` flag
  keeps AD from racing the vault.
- Keep `active.txt` out of version control — it holds a cleartext credential and
  is for local rehearsal only.
