# VMware ESXi

Template scripts for **standalone VMware ESXi** hypervisors (not managed through vCenter). All scripts use the vSphere SOAP API at `https://<host>/sdk` — no agent, no SSH, no extra infrastructure. Adapt them for your environment as needed.

> Standalone ESXi only supports JIT access via local-account creation. vCenter offers richer options (SSO group membership, role grants without local accounts) and will be covered separately when added.

---

## Subdirectories

| Directory | Purpose |
|---|---|
| [`permissions/temp-local-admin/`](permissions/temp-local-admin/README.md) | JIT checkout/checkin of ephemeral local accounts (works for ESXi web UI **or** SSH access) |
| [`rotate/`](rotate/README.md) | Rotate the stored secret of an existing local account |
| [`scans/`](scans/README.md) | Enumerate local accounts and groups for Britive's identity inventory |

---

## Target

| Attribute | Value |
|---|---|
| **Platform** | VMware ESXi (standalone) |
| **Tested versions** | ESXi 7.0, 8.0 |
| **API** | vSphere SOAP at `https://<host>/sdk` |
| **Port** | TCP 443 |
| **Auth** | Local accounts on the host |

---

## Common Prerequisites

The same prerequisites apply to every script in this directory:

- A service account on the ESXi host with the **Administrator** role (or a custom role with `Host.Local.CreateUser`, `Host.Local.RemoveUser`, `Host.Local.ManageUserGroups`, `Authorization.ModifyPermissions`).
- Outbound TCP 443 from the broker host to each target ESXi host.
- `python3` 3.8+ on the broker host (standard library only — no third-party packages).

Each subdirectory README covers ESXi-side setup and Britive Platform setup specific to that script.

---

## ESXi Licensing

Write operations against the vSphere SOAP API — creating users, assigning roles, rotating secrets, starting services — require **vSphere Standard or higher** on the host. Free-edition / unlicensed ESXi disables write API calls after the 60-day evaluation period; only read operations continue to work, which means `permissions/`, `rotate/`, and the user-creation paths in these scripts will fail with a fault. The `scans/` script will continue to work because it only reads. vCenter installs (in [`../vCenter/`](../vCenter/README.md)) always include a paid license, so vCenter scripts have no licensing concern.
