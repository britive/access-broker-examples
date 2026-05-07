# temp-vcenter-admin

Template checkout / checkin scripts for JIT Administrator access to a **VMware vCenter Server**. Unlike the standalone ESXi pattern, no local account is created — vCenter authenticates through SSO, so this template grants the **Administrator role at the vCenter root folder** to the requestor's existing SSO/AD identity, then revokes the grant on checkin. Adapt for your environment — common customer adjustments include scoping the role grant to a non-root inventory object (a specific datacenter, cluster, or host), substituting a custom least-privilege role for Administrator, or transforming the requestor's email into a different principal format (e.g. AD downlevel `EXAMPLE\jdoe`).

The requestor signs in to vCenter with their **usual identity** — there are no ephemeral credentials to hand back. The scripts call the vSphere SOAP API at `https://<vcenter>/sdk` only.

---

## Files

| File | Purpose |
|---|---|
| `checkout.py` | Grant Administrator role at the vCenter root folder to the requestor's principal |
| `checkin.py` | Remove the role binding for that principal at the same entity |

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
| --- | --- |
| `VCENTER_HOST` | IP or hostname of the vCenter Server |
| `VCENTER_SVC_USER` | Service account username (e.g. `britive-svc@vsphere.local`) |
| `VCENTER_SVC_PASSWORD` | Service account secret |
| `BRITIVE_USER_EMAIL` | Britive user email — used as the principal to elevate by default |

### Optional (with defaults)

| Variable | Default | Description |
| --- | --- | --- |
| `VCENTER_PRINCIPAL` | `BRITIVE_USER_EMAIL` | Override the principal that gets elevated. Use this if your identity source format is not email/UPN — e.g. set to `EXAMPLE\jdoe` for AD downlevel logon names |
| `VCENTER_ROLE_ID` | `-1` | Role ID to grant (`-1` = built-in Administrator). For least-privilege, create a custom role in vCenter and set its ID here |
| `VCENTER_ROOT_MOID` | `group-d1` | Inventory entity to grant the role at. Default is the vCenter root folder; change to a `Datacenter`, `ClusterComputeResource`, or `HostSystem` MOID to scope narrower |
| `VCENTER_PROPAGATE` | `true` | Whether the role propagates to children of the entity |
| `VCENTER_VERIFY_TLS` | `false` | Set `true` to verify TLS — vCenter installs often use the built-in self-signed cert |

---

## How It Works

### Checkout (`checkout.py`)

1. Resolves the principal: `VCENTER_PRINCIPAL` if set, otherwise `BRITIVE_USER_EMAIL`.
2. Calls `Login` on `SessionManager` to authenticate the service account.
3. Calls `SetEntityPermissions` on `AuthorizationManager` with the principal, the target entity (`VCENTER_ROOT_MOID`), the role (`VCENTER_ROLE_ID`), and propagation flag.
4. Calls `Logout` and returns:
   ```json
   {"status": "checked_out", "target_host": "<vcenter>", "access_url": "https://<vcenter>/ui", "principal": "<elevated-principal>", "role_id": -1, "entity": "group-d1", "note": "Sign in to vCenter at the URL above with your usual identity. The Administrator role is granted until checkin."}
   ```

### Checkin (`checkin.py`)

1. Resolves the principal the same way checkout did.
2. Calls `Login` on `SessionManager`.
3. Calls `RemoveEntityPermission` on `AuthorizationManager` for the principal at the same entity.
4. Faults of type `NotFound` are treated as success — checkin is idempotent.
5. Calls `Logout` and returns:
   ```json
   {"status": "revoked", "target_host": "<vcenter>", "principal": "<principal>", "entity": "group-d1"}
   ```

---

## vCenter Setup

### 1. Create the service account

In **Administration → Single Sign On → Users and Groups**:

1. Select the `vsphere.local` domain.
2. Create the service account (e.g. `britive-svc`).

### 2. Grant the service account permission to manage role bindings

In **Administration → Access Control → Global Permissions**:

1. **+ Add** → select the service account.
2. Assign a role with at minimum `Permissions.ModifyPermissions`. The built-in **Administrator** role works; for least privilege, create a custom role with only that single privilege.
3. Set scope to the entity tree the broker will manage role bindings on (typically the root, with **Propagate to children** checked).

### 3. (Federated identity sources)

If your vCenter is federated with AD / LDAP / OIDC, the Britive user's email must map to a recognized principal in that identity source. Confirm by signing in to vCenter manually as the requestor — if that works, `SetEntityPermissions` will accept the same principal.

If your identity source uses sAMAccountName (downlevel logon) rather than UPN/email, set `VCENTER_PRINCIPAL` to the right format on the resource type — e.g. `EXAMPLE\jdoe` instead of `jdoe@example.com`.

### 4. Network requirements

- TCP 443 from the broker host to vCenter (SOAP API at `/sdk`).

---

## Broker Container Requirements

- `python3` 3.8+ (standard library only — no third-party packages)
- Outbound TCP 443 to vCenter

---

## Britive Platform Setup

1. Create a broker pool connected to your broker deployment.
2. Create a `vCenter` resource type with `checkout.py` as the checkout script and `checkin.py` as the checkin script.
3. Set the following script parameters on the permission:

   **Always required:** `VCENTER_HOST`, `VCENTER_SVC_USER`, `VCENTER_SVC_PASSWORD`

   **Optional:** `VCENTER_PRINCIPAL`, `VCENTER_ROLE_ID`, `VCENTER_ROOT_MOID`, `VCENTER_PROPAGATE`, `VCENTER_VERIFY_TLS`

4. Mark `VCENTER_SVC_PASSWORD` as **sensitive** so it's encrypted at rest and injected securely at runtime.
5. Set the response template so the requestor sees `{{access_url}}` and `{{note}}` from the checkout output.
6. Assign users or tags to the profile policy.

---

## Example: Manual Test Run

```sh
export VCENTER_HOST="vcenter-01.example.com"
export VCENTER_SVC_USER="britive-svc@vsphere.local"
export VCENTER_SVC_PASSWORD="<service-account-secret>"
export BRITIVE_USER_EMAIL="jane.doe@example.com"

python3 checkout.py
# {"status": "checked_out", "access_url": "https://vcenter-01.example.com/ui",
#  "principal": "jane.doe@example.com", "role_id": -1, "entity": "group-d1", ...}

# To clean up (uses VCENTER_HOST + VCENTER_SVC_USER + VCENTER_SVC_PASSWORD + BRITIVE_USER_EMAIL from above):
python3 checkin.py
# {"status": "revoked", "principal": "jane.doe@example.com", "entity": "group-d1"}
```

---

## Notes

- This template grants the role **at the vCenter root folder** with propagation enabled, which means the requestor inherits Administrator on every datacenter, cluster, host, and VM. To scope tighter, change `VCENTER_ROOT_MOID` to the MOID of the specific entity you want elevated. You can read MOIDs from the vCenter UI URL (e.g. `https://<vcenter>/ui/app/host/host-12`) or via `RetrieveServiceContent` + `PropertyCollector` queries.
- vCenter does not echo "ephemeral credentials" back like the ESXi template does — the requestor uses their existing identity. The audit trail in vCenter shows the actual person, not a synthetic JIT identifier.
- If the requestor already has a standing role binding at the same entity, `SetEntityPermissions` will overwrite it. On checkin, only the binding the script created is removed — pre-existing standing access (if any) is not restored.
- vCenter sessions are by default recorded in `vpxd.log` and the events database. For session recording at the UI level (screen capture / keystrokes), follow the same Bridge + jump-box pattern noted in the ESXi template.
