# Cisco IOS XE – Britive Access Broker Scripts

This directory contains Access Broker scripts for automating privileged access lifecycle management on Cisco **IOS / IOS XE** devices. They were developed and tested on Catalyst 9300; the commands they issue are standard IOS XE and apply equally to Catalyst 9k, ISR, ASR and Catalyst 8000 platforms. Scripts are organized into two functional areas: credential rotation and Just-In-Time privilege escalation.

Not covered here: NX-OS, ASA/FTD and IOS XR use different `username` syntax and need their own variants.

---

## Directory Structure

```
Cisco/
├── rotate/       # Rotate passwords for existing local accounts
└── permissions/  # JIT checkout/checkin of elevated local accounts
```

| Directory | Purpose |
|---|---|
| [`rotate/`](rotate/README.md) | Rotate the password of an existing local user account on one switch or many. Used to keep breakglass and service account credentials from going stale. |
| [`permissions/`](permissions/README.md) | Create a local user account with elevated privilege on checkout and remove it entirely on checkin. Implements Just-In-Time admin access with no standing privilege between sessions. |

---

## Target Devices

| Attribute | Value |
|---|---|
| **Platform** | Cisco IOS / IOS XE devices (Catalyst, ISR, ASR, Catalyst 8000); tested on Catalyst 9300 |
| **Platform** | Cisco Catalyst 9300 Series |
| **OS** | Cisco IOS XE |
| **Minimum IOS XE version** | 16.x — required for `algorithm-type scrypt` (type-9 password hashing) |
| **Management protocol** | SSH (TCP 22) |
| **Authentication** | Local username/password database on the switch |

These scripts interact exclusively with the **local user database** on each switch. They do not require or integrate with TACACS+, RADIUS, or any AAA server. All configuration changes are made in global configuration mode, verified with `show running-config`, and persisted to NVRAM with `write memory`.

If administrators already authenticate through Cisco ISE (TACACS+), consider elevating at the AAA layer instead of on each device; one Britive profile then covers the whole estate. See the Cisco IOS XE section on [learn.britive.com](https://learn.britive.com/integrations/infrastructure/cisco/) for that pattern and for when to prefer these device-direct scripts.
These scripts interact exclusively with the **local user database** on each switch. They do not require or integrate with TACACS+, RADIUS, or any AAA server. All configuration changes are made in global configuration mode and persisted to NVRAM with `write memory`.

---

## IOS XE Privilege Levels

IOS XE assigns every local account a numeric privilege level that controls what commands the account can run after logging in.

| Level | Effective Access |
|---|---|
| **1** | User EXEC — read-only `show` commands; the default for any new local user |
| **2–14** | Custom intermediate levels, populated via `privilege exec level <N>` commands on the switch |
| **15** | Privileged EXEC — equivalent to entering `enable` mode; full administrative access |

All scripts default to **privilege 15** when no explicit level is supplied. The `permissions/` scripts support any level from 2–15 via the `CISCO_ESCALATED_PRIVILEGE` environment variable.

---

## Broker Host Requirements

The server running the Britive Access Broker must meet the following requirements to execute these scripts against a Cisco switch.

### Network Access

| Requirement | Detail |
|---|---|
| **SSH reachability** | TCP port 22 must be open from the broker host to every target switch IP |
| **No additional firewall ports** | All automation uses a single interactive SSH session; no SNMP, NETCONF, or REST API ports are required |
| **Host key trust** | Each device's SSH host key must be trusted on the broker host: `~/.ssh/known_hosts` (or `CISCO_KNOWN_HOSTS`) for Bash, Posh-SSH's trusted-host store for PowerShell. `CISCO_ACCEPT_HOST_KEY=true` relaxes this for labs |

### Admin Account on the Switch

The broker uses a dedicated administrative SSH account (`CISCO_ADMIN_USER`) to connect to each switch. This account must have sufficient privilege to enter global configuration mode and modify user accounts.

| Requirement | Detail |
|---|---|
| **Minimum privilege level** | **15** (privileged EXEC), OR privilege 1 with a known `enable` secret supplied via `CISCO_ENABLE_SECRET` |
| **Required IOS XE capabilities** | `configure terminal`, `username`, `no username`, `write memory` |
| **SSH access** | The account must be permitted to open an SSH session (`transport input ssh` on the vty lines) |
| **Account type** | Local account in the switch's running configuration — not a TACACS+/RADIUS user |

A minimal IOS XE configuration for the broker admin account looks like this:

```
! Local admin account for the Britive broker
username britiveadmin privilege 15 algorithm-type scrypt secret <strong-password>

! Restrict vty lines to SSH only
line vty 0 15
 login local
 transport input ssh
```

> **Principle of least privilege:** If your security policy does not permit a standing privilege-15 account for the broker, create the account at privilege 1 and set `CISCO_ENABLE_SECRET`. The scripts will issue `enable` automatically to reach privileged EXEC before making any configuration changes.

### Software on the Broker Host

Scripts are provided in two language variants. Install whichever matches your broker host OS.

| Variant | Requirements |
|---|---|
| **PowerShell** | PowerShell 5.1+ or 7+; `Posh-SSH` module (`Install-Module Posh-SSH -Scope CurrentUser -Force`) |
| **Bash** | Bash 4.0+; `ssh` (OpenSSH client); `expect` (`apt install expect` / `yum install expect` / `brew install expect`) |

---

## Subdirectory Summaries

### `rotate/` — Password Rotation

Rotates the password of an **existing** local account. The account is not created or removed — only its password (and optionally its privilege level) is updated. This is typically used for breakglass accounts and service accounts that must always exist on the switch. The new secret is generated by the script unless one is supplied, and returned on stdout as JSON for the broker to store.
Rotates the password of an **existing** local account. The account is not created or removed — only its password (and optionally its privilege level) is updated. This is typically used for breakglass accounts and service accounts that must always exist on the switch.

Scripts available:
- Single-switch rotation (PowerShell and Bash)
- Multi-switch rotation — rotates the same account across a comma-separated list of switches in one run (PowerShell and Bash)

See [`rotate/README.md`](rotate/README.md) for full environment variable reference and broker config examples.

### `permissions/` — JIT Privilege Escalation

Implements **Just-In-Time privileged access** via a checkout/checkin pair:

- **Checkout** — creates a prefixed local account (`brt-<user>` by default) at an elevated privilege level (default: 15) with a generated temporary password, and verifies it before saving.
- **Checkin** — removes the account entirely (`no username`), verifies it is gone, and retries on failure, leaving no standing privileged account on the switch.

This means a privileged local account exists **only for the duration of an active Britive session**. Between sessions, the account does not exist in the switch's running configuration.

See [`permissions/README.md`](permissions/README.md) for full environment variable reference, broker config examples, and privilege level guidance.

---

## Output contract

Every script writes progress to **stderr** and exactly one JSON line to **stdout**: checkout returns the credential for the user, rotation returns the new secret for the broker to store, checkin returns nothing. See each subdirectory README for the exact fields. Never capture stdout into a log.

## Choosing the Right Scripts

| Goal | Use |
|---|---|
| Keep a breakglass account's password fresh on a schedule | `rotate/rotate-cisco-account.*` |
| Rotate the same breakglass password across a fleet of switches at once | `rotate/rotate-cisco-account-multi.*` |
| Grant a user temporary admin access to a switch for the duration of a session | `permissions/checkout-cisco-privilege.*` + `permissions/checkin-cisco-privilege.*` |
