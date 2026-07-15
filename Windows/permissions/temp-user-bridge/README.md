# temp-user-bridge (Windows RDP)

Checkout / checkin scripts for JIT Windows RDP access **proxied through the
Britive Bridge (v2)**.

On checkout, a temporary local Windows user is created on the target (via WinRM
or SSH) with a random password, and an `rdp` checkout is registered with the
Bridge. The user connects with a **native RDP client on their workstation**
(Microsoft Remote Desktop, mstsc), pointed at the Bridge's RDP listener, and
authenticates with a **per-checkout Bridge password** — or opens the in-browser
desktop. The Windows account password never leaves the broker/Bridge, and the
session is recorded as screen video.

On checkin, the Bridge checkout is deleted first (closing the proxy session),
then the temp user is removed from its groups and deleted.

---

## Files

| File | Purpose |
|------|---------|
| `checkout_rdp_bridge.sh` | Create temp Windows user + register Bridge RDP session |
| `checkin_rdp_bridge.sh`  | Terminate Bridge session + delete temp Windows user |

---

## How the user connects

The checkout returns everything needed:

- **Native RDP client** — connect to `rdp_address` (`<bridge-host>:3389` —
  the port the ECS deployment's NLB exposes for RDP), username
  `<email>%<target-host>`, password = the per-checkout Bridge password.
  With `NATIVE_AUTH=ldap` the user enters their directory password instead.
- **Browser** — `{{url}}` opens the in-browser desktop
  (`/connect?transaction_id=<TRX>`).

The Bridge's native RDP listener requires a TLS certificate
(`rdp.native.tls_cert` / `tls_key`) — RDP clients expect a certificate-backed
connection.

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
|----------|-------------|
| `BRITIVE_USER_EMAIL` | Requesting user's email — local part becomes the Windows username (SAM-safe, max 20 chars) |
| `TRX` | Britive transaction ID for this checkout |
| `TARGET_HOST` | Hostname or IP of the Windows RDP target |
| `BRIDGE_URL` | Public base URL of the Bridge — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET_PORT` | `3389` | RDP port on the target |
| `TARGET_DOMAIN` | — | Windows/AD domain for the RDP login |
| `NATIVE_PORT` | `3389` | Port of the Bridge's native RDP listener |
| `NATIVE_AUTH` | `bridge_credentials` | `bridge_credentials` (generated password) or `ldap` |
| `RDP_SECURITY` | `nla` | `any`, `nla`, `tls`, or `rdp` |
| `RDP_ENABLE_DRIVE` | `false` | Allow drive redirection (file copy) |
| `BRITIVE_FIRST_NAME` / `BRITIVE_LAST_NAME` | — | Account display name (falls back to email local part) |
| `LOCAL_GROUP` | `Remote Desktop Users` | Comma-separated local groups for the temp user |
| `PROVISION_TRANSPORT` | `winrm` | `winrm` or `ssh` (Windows OpenSSH) |
| `PROVISION_HOST` | `TARGET_HOST` | Override if provisioning host differs |
| `PROVISION_USER` | `Administrator` | Privileged account for provisioning |
| `PROVISION_PASSWORD` | — | **Required for winrm transport** |
| `PROVISION_PORT` | `5985`/`5986` (winrm), `22` (ssh) | Provisioning port |
| `PROVISION_KEY` | `/home/bridge/.ssh/id_ed25519` | SSH provisioning key path |
| `PROVISION_KEY_PEM` | — | Inline PEM key content (preferred; written to tmpfs) |
| `WINRM_NO_SSL` | `1` | `1` = HTTP/5985, `0` = HTTPS/5986 |
| `BROKER_API` | `/opt/britive-broker/scripts/broker-bridge-api.sh` | Path to the Bridge API helper CLI |

---

## How It Works

### Checkout (`checkout_rdp_bridge.sh`)

1. Derives a SAM-safe Windows username from the user's email (lowercase
   alphanumeric, `brg` prefix if it starts with a digit, max 20 chars).
2. Generates a random password meeting Windows complexity — **only the Bridge
   ever sees it**.
3. Runs a PowerShell provisioning script on the target (WinRM via `pywinrm`,
   or SSH + `powershell.exe -EncodedCommand`): creates the user (or resets the
   password), tags it `bridge:<TRX>`, adds it to `LOCAL_GROUP`.
4. Registers an `rdp` checkout with the Bridge
   (`broker-bridge-api.sh checkout-create`) carrying the account credentials,
   `rdp_security`, `native_auth` settings, and expiry.
5. Returns JSON for the response template:

   ```json
   {
     "token": "<token>",
     "url": "https://bridge.example.com/connect?transaction_id=<TRX>",
     "rdp_address": "bridge.example.com:3389",
     "bridge_username": "bob@corp%win-jump.corp.local",
     "bridge_password": "<generated>",
     "bridge_host": "bridge.example.com",
     "bridge_port": "3389",
     "target_username": "bobcorp"
   }
   ```

   Surface `{{rdp_address}}` and `{{bridge_password}}` in the response
   template; `{{url}}` for the browser desktop.

### Checkin (`checkin_rdp_bridge.sh`)

1. Deletes the Bridge checkout **first** (`broker-bridge-api.sh
   checkout-delete <TRX>`) so the proxy session closes before the account
   disappears.
2. Removes the temp user from its groups and deletes the account
   (best-effort — warnings, not failures, if already gone).

---

## Bridge Requirements

Native RDP mode must be enabled on the Bridge (off by default) **with a TLS
cert and key** — the Bridge will not start native RDP without them:

```yaml
rdp:
  idle_timeout: 30m
  native:
    enabled: true
    listen: "3389"
    tls_cert: "/data/certs/rdp-cert.pem"
    tls_key: "/data/certs/rdp-key.pem"
  browser:
    enabled: true
```

The Bridge needs network reachability to the target on `TARGET_PORT`, and users
must reach the Bridge on `NATIVE_PORT` (ECS NLB exposes `3389`).

Per-checkout RDP controls available in the payload: `rdp_disable_copy`,
`rdp_disable_paste`, `rdp_clipboard_save_files`, `lock_blocks_screen`,
`rdp_color_depth`, `rdp_server_layout`, `rdp_timezone`, and visual-fidelity
toggles — add to the payload in `checkout_rdp_bridge.sh` as needed.

---

## Target Host Requirements

- **WinRM transport**: WinRM enabled on the target; `PROVISION_USER` with local
  admin rights; NTLM auth (default `WINRM_NO_SSL=1` → HTTP/5985 — use HTTPS in
  production).
- **SSH transport**: Windows OpenSSH server; provisioning key installed for
  `PROVISION_USER`; PowerShell available.

## Broker Container Requirements

- `python3` (+ `pywinrm` for WinRM transport: `pip install pywinrm`), `jq`
- `ssh` for SSH transport
- `broker-bridge-api.sh` at `BROKER_API` path

---

## Security Notes

- The Windows account password is generated at checkout, passed to the Bridge
  as `target_password`, and never returned to the user.
- The Bridge password is per-checkout and dies with the transaction on checkin
  or expiry.
- `RDP_SECURITY=nla` (default) enforces Network Level Authentication to the
  target.
- Checkin order matters: Bridge session is revoked **before** the account is
  deleted, so no orphaned live session survives the account removal.
