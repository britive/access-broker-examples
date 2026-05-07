# scans

Template script that discovers local accounts and groups on a standalone **VMware ESXi** host via the vSphere SOAP API and writes a Britive Resource Manager scan report so Britive's identity inventory stays current.

Adapt for your environment — common customer adjustments include filtering accounts by prefix, adding custom attributes, or extending the report with permission assignments pulled from `AuthorizationManager`.

---

## Files

| File | Purpose |
|---|---|
| `scan-esxi-users.py` | Enumerate local accounts and groups; write a Britive Resource Manager JSON report |

---

## Environment Variables

### Required

| Variable | Description |
| --- | --- |
| `ESXI_HOST` | IP or hostname of the target ESXi host |
| `ESXI_SVC_USER` | Service account on the host (must hold the Administrator role) |
| `ESXI_SVC_PASSWORD` | Service account secret |
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Output file path — auto-injected by Britive at scan time |

### Optional

| Variable | Default | Description |
| --- | --- | --- |
| `ESXI_VERIFY_TLS` | `false` | Set `true` to verify TLS — most standalone ESXi hosts use self-signed certs |

---

## How It Works

1. Calls `Login` on `ha-sessionmgr` to authenticate the service account.
2. Calls `RetrieveUserGroups` on `ha-user-directory` twice — once with `findUsers=true`, once with `findGroups=true`.
3. Parses each `<returnval>` block for `principal`, `fullName`, `shellAccess`, `id`.
4. Builds a Britive Resource Manager output document and writes it to `BROKER_INJECTED_SCAN_OUTPUT_PATH`.
5. On any failure, writes a document with empty `data` arrays and the failure recorded in `metadata.scan_errors`, then exits `1`.

---

## Output Format

The script writes a JSON document with the shape Britive's Resource Manager expects:

```
{
  "data": {
    "identities": [...],         # one entry per local account on the host
    "groups": [...],             # one entry per local group on the host
    "permissions": [],           # empty — defined in the resource type, not from scan
    "permission_mapping": []     # empty — defined in the resource type, not from scan
  },
  "metadata": {
    "resource_id": "<ESXI_HOST>",
    "resource_type": "ESXi",
    "scan_time": "<ISO-8601 UTC>",
    "scan_details": "ESXi scan completed. Users: N, Groups: N",
    "scan_errors": "",
    "attribute_resolution": {
      "group_membership": "id",
      "permission_mapping": "id"
    }
  }
}
```

Each identity entry includes `id`, `name`, `type`, `description`, `created_on`, `is_active`, and an `attributes` block with `email`, `first_name`, `last_name`, `shell_access`, `posix_id`. Each group entry includes `id`, `name`, `type`, `description`, `created_on`, `is_active`, `members`, `attributes`.

> **`permissions` and `permission_mapping` are empty by design.** Britive checkout permissions for this resource type are defined in the resource type itself, not derived from this scan. The scan exists to keep the identity inventory current.

---

## Setup

ESXi service-account setup, broker requirements, and Britive Platform setup are the same as for [`../permissions/temp-local-admin/`](../permissions/temp-local-admin/README.md#esxi-host-setup) — register `scan-esxi-users.py` as the scan script on the resource type. `BROKER_INJECTED_SCAN_OUTPUT_PATH` is supplied automatically by Britive — do not configure it.

---

## Example

```sh
export ESXI_HOST="esxi-01.example.com"
export ESXI_SVC_USER="britive-svc"
export ESXI_SVC_PASSWORD="<service-account-secret>"
export BROKER_INJECTED_SCAN_OUTPUT_PATH="/tmp/esxi-scan.json"

python3 scan-esxi-users.py
# [scan] Found 3 user(s)
# [scan] Found 1 group(s)
# [scan] Output written to /tmp/esxi-scan.json
```
