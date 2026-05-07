# VMware vCenter

Template scripts for **VMware vCenter Server** (8.x). Adapt them for your environment as needed.

vCenter has a fundamentally different identity model than standalone ESXi — it does not have a `HostLocalAccountManager`-style SOAP API for creating local accounts on the box. Authentication goes through **vCenter Single Sign-On**, with users coming from either the local SSO domain (`vsphere.local`) or a federated identity source (AD, LDAP, ADFS, OIDC). The realistic JIT pattern is therefore **role grant on an existing identity**, not "create a temp user." See [`permissions/temp-vcenter-admin/`](permissions/temp-vcenter-admin/README.md) for the baseline.

> Why not "elevate to each ESXi through vCenter"? You can — `SetEntityPermissions` works at any inventory level, including individual `HostSystem` objects — but the audit story gets muddier (one role binding per host, propagation flags to manage, scope drift if hosts move datacenters). The simpler "Administrator at vCenter root" pattern covers the common case. Customers needing per-host scoping can adapt the entity MOID in `checkout.py`.

---

## Subdirectories

| Directory | Purpose |
|---|---|
| [`permissions/temp-vcenter-admin/`](permissions/temp-vcenter-admin/README.md) | JIT Administrator role grant at the vCenter root for an existing SSO/AD identity |

---

## Target

| Attribute | Value |
|---|---|
| **Platform** | VMware vCenter Server |
| **Tested versions** | vCenter 8.0 |
| **API** | vSphere SOAP at `https://<vcenter>/sdk` |
| **Port** | TCP 443 |
| **Auth** | vCenter SSO (local domain `vsphere.local` or federated AD/LDAP/OIDC) |

---

## Common Prerequisites

- A service account in vCenter SSO with the `Administrator` role at the root, **or** a custom role with at minimum `Permissions.ModifyPermissions` at every entity where you grant or revoke role bindings. Service-account names are usually `<user>@vsphere.local` for local SSO accounts.
- Outbound TCP 443 from the broker host to vCenter.
- `python3` 3.8+ on the broker host (standard library only — no third-party packages).

---

## What's Not Here (and Why)

| Pattern | Why deferred |
|---|---|
| `rotate/` | Local SSO users do exist (`<user>@vsphere.local`), but rotation needs the SSO Admin API at `/sso-adminserver/sdk/vsphere.local` — a separate endpoint with its own envelope shape. Most customers federate SSO with AD and rotate there, not in vCenter. Add only if you have a real use case. |
| `scans/` | Walking SSO domain users for Britive's identity inventory is a bigger lift than the ESXi local-account scan — the same SSO Admin API is involved, plus SAML group resolution. Add when needed. |
| Per-host elevation through vCenter | Solvable but adds complexity (one binding per host, propagation flags, scope drift). The "Administrator at vCenter root" template covers the common case; customize the entity MOID for narrower scopes. |
