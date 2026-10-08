# Palo Alto Networks – Britive Access Broker Scripts

Access Broker scripts for **PAN-OS** firewalls and **Panorama**. Both expose the same XML API on the management interface, and all scripts here use it; nothing is installed on the device. Python 3, standard library only.

```
Palo Alto Networks/
├── permissions/
│   └── jit-admin/     # Temporary local administrator at checkout, deleted at checkin
└── rotate/            # Rotate an existing administrator's password (break-glass)
```

| Directory | Use case |
|---|---|
| [`permissions/jit-admin/`](permissions/jit-admin/README.md) | Ephemeral access and role elevation: `superreader` for read-only, `superuser` for full admin, `panorama-admin`, or any custom Admin Role profile |
| [`rotate/`](rotate/README.md) | Keep the built-in `admin` (and any other local administrator) vaulted and rotated |

If administrators authenticate through **Cisco ISE / TACACS+**, elevation can instead come from the TACACS+ attribute `PaloAlto-Admin-Role` returned by an ISE shell profile; see `Cisco ISE/permissions/identity-group/`. Keep the local `admin` as break-glass for when the AAA server is unreachable, and rotate it with the scripts here.

---

## How it works

```
Britive → Broker ──HTTPS XML API──► PAN-OS / Panorama
                     keygen → request password-hash → config edit/delete mgt-config/users
                     → commit partial admin <broker-user> → poll job → verify
```

Every change is committed with **`commit partial`** scoped to the broker's own admin account, so the broker never commits another administrator's pending candidate changes, and theirs are not blocked by ours. The commit job is polled until it finishes; a failed job fails the checkout.

---

## Broker Host Requirements

| Requirement | Detail |
|---|---|
| **Network** | TCP 443 from the broker to the firewall/Panorama management address (or `PANOS_PORT`) |
| **API admin** | A local administrator for the broker, `superuser` or a custom Admin Role profile with XML API access, *Device > Administrators* and *Commit* enabled. Password in the Britive Secrets Store (`PANOS_API_PASSWORD`), or a pre-generated key in `PANOS_API_KEY` |
| **TLS** | The management certificate is verified by default. Point `PANOS_CA_BUNDLE` at your CA or set `PANOS_VERIFY_TLS=false` for a lab |
| **Software** | Python 3.8+ |

The requesting identity comes from `BRITIVE_USER_EMAIL`. Admin names are limited to letters, digits, `.`, `-`, `_` and 31 characters; the scripts derive `brt-<local-part>` and truncate.

---

## Output contract

Progress on **stderr**, one JSON line on **stdout** (checkout: the credential; rotation: the new secret; checkin: nothing). Never capture stdout into a log.

## Panorama-managed firewalls

Administrators are a device-local object; a firewall's `mgt-config/users` is not pushed from Panorama. Run `jit-admin` against the firewall for firewall access and against Panorama for Panorama access. For Panorama, use `PANOS_ROLE=panorama-admin` or a custom Panorama Admin Role profile, and scope the profile with access domains in the role profile itself.

## High availability

Local administrators are synchronized between HA peers, so one checkout against the active peer is enough. Point `PANOS_HOST` at the active member's management address or a VIP; the API refuses config changes on the passive peer.
