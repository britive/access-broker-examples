# Cisco ISE – Britive Access Broker Scripts

Access Broker scripts for **Cisco Identity Services Engine (ISE)**. ISE plays two roles in a Britive deployment, and this directory covers both:

1. **ISE as the AAA pivot for the network estate.** Devices authenticate administrators through ISE (TACACS+ Device Administration or RADIUS). Britive changes the user's identity group at checkout; ISE's authorization policy turns that group into a privilege level and command set at login. One profile elevates on every device ISE fronts, with no per-device change.
2. **ISE as a target.** The ISE appliance itself has privileged accounts — the CLI (ADE-OS) administrators reachable over SSH and the GUI administrators of the admin portal. Britive issues them just-in-time and keeps the break-glass ones rotated.

All scripts talk to ISE directly: ERS over HTTPS for identity-store changes, SSH for the appliance CLI. No agent is installed on ISE. Python scripts use only the standard library.

---

## Directory Structure

```
Cisco ISE/
├── permissions/
│   ├── identity-group/   # Add/remove an ISE internal user in an identity group (AAA-driven elevation)
│   └── cli-admin/        # JIT CLI (ADE-OS) administrator on an ISE node
└── rotate/               # Rotate CLI and GUI admin passwords (break-glass)
```

| Directory | Mechanism | Use case |
|---|---|---|
| [`permissions/identity-group/`](permissions/identity-group/README.md) | ERS API (`internaluser`, `identitygroup`) | Estate-wide JIT elevation through ISE policy |
| [`permissions/cli-admin/`](permissions/cli-admin/README.md) | SSH + `expect` | Ephemeral CLI admin on the appliance |
| [`rotate/`](rotate/README.md) | SSH + `expect` | Rotate the built-in `admin` (GUI) and CLI admins |

---

## Which pattern

| You want to… | Use |
|---|---|
| Elevate someone on all switches/firewalls that authenticate via ISE, for an hour | `identity-group` (if the user is in ISE's internal store) or the Active Directory group-membership scripts (if ISE reads AD) |
| Give someone shell access to an ISE node to troubleshoot | `cli-admin` |
| Keep the ISE `admin` GUI password and CLI `admin` password vaulted and rotated | `rotate` |
| Give someone temporary access to the ISE admin portal | Map ISE admin groups to an external identity source (AD or ISE internal) and use `identity-group` / AD group membership. ERS cannot create GUI administrators, so there is no script for that |

Group changes do not end sessions that are already open. TACACS+ authorizes at login; an elevated session stays elevated until it closes. Put Britive Bridge in front of the devices so the session ends when the checkout expires.

---

## Broker Host Requirements

| Requirement | Detail |
|---|---|
| **ERS** | TCP 9060 from the broker to the Primary Admin Node. ERS enabled under *Administration > System > Settings > API Settings*. An admin in the **ERS Admin** group (read/write) stored in the Britive Secrets Store |
| **SSH** | TCP 22 to each ISE node you manage CLI accounts on. CLI accounts are **node-local**; register each node as its own resource |
| **CLI admin** | An existing ADE-OS admin (`role admin`) the broker logs in as |
| **Host keys** | Each node's SSH host key in the broker user's `known_hosts` (or `ISE_KNOWN_HOSTS`); `ISE_ACCEPT_HOST_KEY=true` for labs |
| **Software** | Python 3.8+ (identity-group); Bash 4+, OpenSSH client and `expect` (cli-admin, rotate) |
| **TLS** | ERS calls verify the ISE certificate by default. Point `ISE_CA_BUNDLE` at your CA, or set `ISE_VERIFY_TLS=false` for a lab |

The Britive-injected identity is read from `BRITIVE_USER_EMAIL`; its local part (`alice`) is the ISE username unless `ISE_USERNAME` overrides it.

---

## Output contract

Every script writes progress to **stderr** and at most one JSON line to **stdout**: `identity-group` checkout returns the group that was granted (no credential — the user keeps their own password), `cli-admin` checkout and both rotation scripts return the credential, checkins return nothing. Never capture stdout into a log.

---

## Related

- `Cisco/` — device-direct scripts for IOS XE local accounts, for devices not behind ISE and for break-glass accounts that must work when ISE is down
- `Active Directory/` — group-membership checkout/checkin when ISE reads AD
- `Palo Alto Networks/` — PAN-OS admins can also take their role from an ISE TACACS+ shell profile (`PaloAlto-Admin-Role`), so the `identity-group` pattern covers firewalls too
