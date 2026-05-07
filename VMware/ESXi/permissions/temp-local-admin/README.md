# temp-local-admin

Template checkout / checkin scripts for JIT admin access to a standalone **VMware ESXi** host. The same JIT account works for **either the host web UI or SSH** — the script creates the account with shell access enabled (`shellAccess=true`), so it can be used both ways. SSH is only usable if the host's SSH service is enabled (it is disabled by default on ESXi). Adapt for your environment — common customer adjustments include changing the JIT account naming convention, scoping the role grant to a non-root inventory object, or replacing the Administrator role with a custom least-privilege role.

On checkout, an ephemeral local account is created on the host and granted the Administrator role at the root inventory object. The account name is the requestor's email local part — `clint.pollock@example.com` becomes `clint.pollock` — so the audit trail on the ESXi host names the actual person, not a synthetic JIT identifier. The requestor receives the host UI URL, an SSH command, and the ephemeral sign-in credentials. On checkin, the role assignment is removed and the account is deleted. All API calls go to the vSphere SOAP endpoint at `https://<host>/sdk` — no SSH, no agent, no extra infrastructure on the broker side.

> Standalone ESXi only supports JIT via creation of an ephemeral local account — there is no SSO/AD integration on a single host. vCenter (planned) offers other options like SSO group membership and role grants on existing identities.

---

## Files

| File | Purpose |
|---|---|
| `checkout.py` | Create the JIT account + assign Administrator + return host URL, SSH command, and credentials |
| `checkin.py` | Remove the JIT account's role assignment + delete the account |

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
| --- | --- |
| `ESXI_HOST` | IP or hostname of the target ESXi host |
| `ESXI_SVC_USER` | Service account on the host (must hold the Administrator role) |
| `ESXI_SVC_PASSWORD` | Service account secret |
| `BRITIVE_USER_EMAIL` | Britive user email — used to derive the JIT account name (both checkout and checkin) |

### Optional (with defaults)

| Variable | Default | Description |
| --- | --- | --- |
| `ESXI_VERIFY_TLS` | `false` | Set `true` to verify TLS — most standalone ESXi hosts use self-signed certs |

---

## How It Works

### Checkout (`checkout.py`)

1. Derives the JIT account name from `BRITIVE_USER_EMAIL` — the lowercase email local part with anything outside `[a-z0-9._-]` stripped (e.g. `clint.pollock@example.com` → `clint.pollock`).
2. Generates an ephemeral sign-in secret (random, 18 chars).
3. Calls `Login` on `ha-sessionmgr` to authenticate the service account.
4. Calls `CreateUser` on `ha-localacctmgr` to create the JIT account with `shellAccess=true`. If the account already exists, `UpdateUser` is called instead to refresh the secret. ⚠ **See "Name Collision" below.**
5. Calls `SetEntityPermissions` on `ha-authmgr` to bind the JIT account to the Administrator role at `ha-folder-root` with `propagate=true`.
6. Calls `Logout` and returns:
   ```json
   {"status": "checked_out", "target_host": "<host>", "access_url": "https://<host>/ui", "ssh_command": "ssh <jit-name>@<host>", "username": "<jit-name>", "password": "<ephemeral-secret>", "note": "..."}
   ```

### Checkin (`checkin.py`)

1. Derives the JIT account name the same way checkout did, from `BRITIVE_USER_EMAIL`.
2. Calls `Login` on `ha-sessionmgr` to authenticate the service account.
3. Calls `RemoveEntityPermission` on `ha-authmgr` to drop the role binding for that account.
4. Calls `RemoveUser` on `ha-localacctmgr` to delete the account.
5. Faults of type `NotFound` / `UserNotFound` are treated as success — checkin is idempotent.
6. Calls `Logout` and returns:
   ```json
   {"status": "revoked", "target_host": "<host>", "removed_user": "<jit-name>"}
   ```

---

## Name Collision

Because the JIT account name is the email local part with no prefix, a checkout for `clint.pollock@example.com` will hit any pre-existing local account named `clint.pollock` on the host — and the script's "AlreadyExists → UpdateUser" path will **overwrite that account's secret** with the ephemeral JIT secret. On checkin, the account will then be deleted.

**This is fine when ESXi local accounts are managed exclusively through Britive.** If the host has manually-created admin accounts that share names with Britive user emails, you have two options:

1. Keep this behavior and ensure manually-created accounts on the host don't share names with Britive user emails.
2. Reintroduce a small prefix in `jit_username()` (e.g. `b-clint.pollock`) so JIT accounts can never collide with manually-created ones.

---

## ESXi Host Setup

### 1. Create the service account

Sign in to the ESXi Host Client as `root`:

1. **Manage → Security & users → Users → Add user**.
2. Create the service account (e.g. `britive-svc`).

### 2. Assign the Administrator role

1. **Host → Actions → Permissions → Add user**.
2. Select the service account and assign the **Administrator** role at the root inventory object with **Propagate to children** checked.

### 3. (Optional) Use a custom role instead of Administrator

If your security policy does not permit a standing Administrator account for the broker, create a custom role with at minimum:

- `Host.Local.CreateUser`
- `Host.Local.RemoveUser`
- `Host.Local.ManageUserGroups`
- `Authorization.ModifyPermissions`

### 4. (Optional) Enable SSH on the host

The JIT account is created with shell access enabled, but the host's SSH service must be running for the SSH path to work. SSH is disabled by default on ESXi. To enable it permanently:

1. **Manage → Services → TSM-SSH → Start** (and **Actions → Policy → Start and stop with host** to persist across reboots).

If SSH is left disabled, requestors can still use the web UI URL — the SSH command in the checkout output will simply fail to connect.

### 5. Network requirements

- TCP 443 from the broker host to each target ESXi host (SOAP API at `/sdk`).
- TCP 22 from requestor workstations to each target ESXi host — only if SSH is enabled and you want requestors to use the SSH path.

---

## Broker Container Requirements

- `python3` 3.8+ (standard library only — no third-party packages)
- Outbound TCP 443 to each target ESXi host

---

## Britive Platform Setup

1. Create a broker pool connected to your broker deployment.
2. Create an `ESXi` resource type with `checkout.py` as the checkout script and `checkin.py` as the checkin script.
3. Set the following script parameters on the permission:

   **Always required:** `ESXI_HOST`, `ESXI_SVC_USER`, `ESXI_SVC_PASSWORD`

   **Optional:** `ESXI_VERIFY_TLS`

4. Mark `ESXI_SVC_PASSWORD` as **sensitive** so it's encrypted at rest and injected securely at runtime.
5. Set the response template so the requestor sees `{{access_url}}`, `{{ssh_command}}`, `{{username}}`, and `{{password}}` from the checkout output.
6. Assign users or tags to the profile policy.

---

## Example: Manual Test Run

```sh
export ESXI_HOST="esxi-01.example.com"
export ESXI_SVC_USER="britive-svc"
export ESXI_SVC_PASSWORD="<service-account-secret>"
export BRITIVE_USER_EMAIL="clint.pollock@example.com"

python3 checkout.py
# {"status": "checked_out", "access_url": "https://esxi-01.example.com/ui",
#  "ssh_command": "ssh clint.pollock@esxi-01.example.com",
#  "username": "clint.pollock", ...}

# To clean up (uses ESXI_HOST + ESXI_SVC_USER + ESXI_SVC_PASSWORD + BRITIVE_USER_EMAIL from above):
python3 checkin.py
# {"status": "revoked", "removed_user": "clint.pollock"}
```

---

## Possible Extension: enable SSH on the host at checkout

The JIT account is created with shell access enabled, but the SSH path only works if the host's `TSM-SSH` service is running — and it's disabled by default on ESXi. `checkout.py` includes a commented-out `esxi_start_ssh_service()` helper that calls `StartService` on `HostServiceSystem` to bring SSH up automatically at checkout, gated on an opt-in `ESXI_ENABLE_SSH=true` env var.

**This extension is untested** in this template. Before enabling it:

- Verify the `HostServiceSystem` MOID on your host (the script uses `serviceSystem`, the standard for standalone ESXi).
- Grant the service account `Host.Config.Settings` in addition to the user/permission privileges it already has.
- Decide whether checkin should restore the prior service state (read it before starting, stop on checkin if it was off). Not modeled in the commented helper.

A simpler alternative: leave SSH always-on by configuring **Manage → Services → TSM-SSH → Policy → Start and stop with host** in the Host Client (one-time), and let the script just hand back the SSH command.

---

## Session Recording

These scripts return ephemeral credentials to the requestor for direct sign-in (web UI or SSH). **Sessions are not recorded.**

If your environment requires recorded sessions, the recommended pattern is to use the **Britive Bridge** in front of a Windows jump box: have the bridge open the ESXi UI (or an SSH client) inside the recorded jump-box session and inject the JIT credentials at sign-in time, so the secret is never exposed to the requestor. Record the jump box itself via RDP session recording.

That flow is out of scope for this example — it requires bridge + jump-box infrastructure not modeled here.
