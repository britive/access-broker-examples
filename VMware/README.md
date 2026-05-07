# VMware

Template Britive Access Broker scripts for VMware products. All scripts in this directory talk to the target host via the **vSphere SOAP API** at `https://<host>/sdk` — no agent or extra service required on the target.

These are starting points — adapt them for your environment as needed.

---

## Subdirectories

| Directory | Purpose |
|---|---|
| [`ESXi/`](ESXi/README.md) | Standalone ESXi hypervisor — JIT local accounts, account rotation, IAM scans |
| [`vCenter/`](vCenter/README.md) | vCenter Server — JIT role grants on existing SSO/AD identities |

---

## Common Concepts

| Requirement | Detail |
|---|---|
| **Network** | TCP 443 from the broker host to each target ESXi/vCenter |
| **Auth** | A SOAP service account on the host with permission to manage local accounts and roles |
| **Broker host** | Python 3.8+ with the standard library (no third-party packages required) |
