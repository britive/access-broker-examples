# rotate

Template script that rotates an existing local account on a standalone **VMware ESXi** host via the vSphere SOAP API at `https://<host>/sdk`. The account itself is not created or removed — only its stored secret is updated.

Adapt for your environment — common customer adjustments include batching across multiple hosts, post-rotation hooks (e.g. push the new secret to a vault), or coordinating rotations with maintenance windows.

---

## Files

| File | Purpose |
|---|---|
| `rotate-esxi-account.py` | Rotate one local account on a single ESXi host |

---

## Environment Variables

### Required

| Variable | Description |
| --- | --- |
| `ESXI_HOST` | IP or hostname of the target ESXi host |
| `ESXI_SVC_USER` | Service account on the host (must hold the Administrator role) |
| `ESXI_SVC_PASSWORD` | Service account secret |
| `ESXI_TARGET_USER` | Local account to rotate |
| `ESXI_NEW_PASSWORD` | New secret to set on the target account |

### Optional

| Variable | Default | Description |
| --- | --- | --- |
| `ESXI_VERIFY_TLS` | `false` | Set `true` to verify TLS — most standalone ESXi hosts use self-signed certs |

---

## How It Works

Calls `Login` on `ha-sessionmgr`, then `UpdateUser` on `ha-localacctmgr` with the target account's `id` and the new secret, then `Logout`. Exits `0` on success, `1` on any failure. Secrets are never written to stdout or logs.

---

## Setup

ESXi service-account setup, broker requirements, and Britive Platform setup are the same as for [`../permissions/temp-local-admin/`](../permissions/temp-local-admin/README.md#esxi-host-setup) — register `rotate-esxi-account.py` as the rotation script on the resource type and mark `ESXI_SVC_PASSWORD` and `ESXI_NEW_PASSWORD` as **sensitive**.

---

## Example

```sh
export ESXI_HOST="esxi-01.example.com"
export ESXI_SVC_USER="britive-svc"
export ESXI_SVC_PASSWORD="<service-account-secret>"
export ESXI_TARGET_USER="root"
export ESXI_NEW_PASSWORD="<new-secret>"

python3 rotate-esxi-account.py
# [rotate] Rotating secret for root
# [rotate] Secret rotated successfully for root
```

---

## Notes

- The new secret is sent to the host inside the encrypted HTTPS session — never over plain text.
- TLS verification defaults off because most standalone ESXi hosts use self-signed certs. Set `ESXI_VERIFY_TLS=true` once you've installed a CA-trusted cert on the host.
- ESXi enforces password complexity rules via PAM. If `UpdateUser` fails with a complexity-related fault, generate a stronger secret and retry.
