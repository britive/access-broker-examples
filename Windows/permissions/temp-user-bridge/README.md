# temp-user-bridge (Windows RDP)

Checkout / checkin scripts for JIT Windows RDP access **proxied through the
Britive Bridge (v2)**.

On checkout, a temporary local Windows user is created on the target (via WinRM
or SSH) with a random password, and an `rdp` checkout is registered with the
Bridge carrying the caller's **bridge credential**
(`native_auth=bridge_credentials`). The user connects with a **native RDP client
on their workstation** (Microsoft Remote Desktop, mstsc), pointed at the
Bridge's RDP listener, and authenticates with the **Bridge Username/Password set
on their Britive profile** (Manage Account → Bridge Attributes) — the broker
injects these to the script as `BRIDGE_AUTH_*` env vars — or opens the
in-browser desktop. The Windows account password never leaves the broker/Bridge,
and the session is recorded as screen video.

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

- **Native RDP client** — `command` (`mstsc /v:<bridge-host>:3389` — the port
  the ECS deployment's NLB exposes for RDP; one NLB fronts both the web tier
  and every native listener, so browser and native clients use the same host),
  username `<email>%<target-host>`
  where `<email>` is the user's Britive identity (`BRITIVE_USER_EMAIL`) — must
  equal the checkout owner / SSO identity, not the profile "Bridge Username"
  field. Password = the Bridge Password from the profile (`BRIDGE_AUTH_PASSWORD`).
- **Browser** — `{{browser_session}}` opens the in-browser desktop
  (`https://<bridge-host>/rdp/#transaction_id=<TRX>`).

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
| `BRIDGE_URL` | Bridge hostname — one NLB serves both browser and native sessions, e.g. `bridge.example.com` — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |
| `BRIDGE_AUTH_PASSWORD` | Bridge password from the profile; broker-injected. Entered at the RDP client credential prompt. The native login username is the user's email (`BRITIVE_USER_EMAIL`), not a separate bridge username |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET_PORT` | `3389` | RDP port on the target |
| `TARGET_DOMAIN` | — | Windows/AD domain for the RDP login |
| `NATIVE_PORT` | `3389` | Port of the Bridge's native RDP listener |
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
   `rdp_security` settings, expiry, and the bridge credential
   (`native_auth=bridge_credentials` + `bridge_auth_password`).
5. Returns JSON in the standard Bridge checkout schema (same keys as the
   Linux SSH and MySQL bridge checkouts, so one response template covers
   all of them):

   ```json
   {
     "BRIDGE_URL": "bridge.example.com",
     "command": "mstsc /v:bridge.example.com:3389",
     "auth_method": "password",
     "bridge_username": "alice@corp%win-jump.corp.local",
     "bridge_port": "3389",
     "target_username": "bobcorp",
     "browser_session": "https://bridge.example.com/rdp/#transaction_id=<TRX>"
   }
   ```

   Surface `{{command}}` and `{{bridge_username}}` in the response template;
   the password is the Bridge Password from the user's Britive profile.
   `{{browser_session}}` opens the in-browser desktop.

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
- The bridge password (`BRIDGE_AUTH_PASSWORD`) comes from the user's Britive
  profile via the broker and is registered on the checkout as
  `bridge_auth_password`; the checkout dies with the transaction on
  checkin or expiry.
- `RDP_SECURITY=nla` (default) enforces Network Level Authentication to the
  target.
- Checkin order matters: Bridge session is revoked **before** the account is
  deleted, so no orphaned live session survives the account removal.
