# temp-user-bridge (Linux SSH)

Checkout / checkin scripts for JIT Linux SSH access **proxied through the Britive
Bridge (v2)**.

On checkout, a temporary Linux user is provisioned on the target with a one-time
`ed25519` key (used only by the Bridge to reach the target), and an `ssh`
checkout is registered with the Bridge carrying the caller's **bridge
credential** (`native_auth=bridge_credentials`). The user connects with their
**local `ssh` client on their workstation**, pointed at the Bridge's native SSH
listener, and authenticates with the **Bridge Username/Password (or Bridge SSH
Key) set on their Britive profile** (Manage Account → Bridge Attributes) — the
broker injects these to the script as `BRIDGE_AUTH_*` env vars — or opens the
in-browser terminal. The one-time private key never leaves the broker/Bridge,
and the session is fully brokered and recorded.

On checkin, the Bridge checkout is deleted (terminating any active session),
then the one-time key and sudoers entry are removed from the target.

---

## Files

| File | Purpose |
|------|---------|
| `checkout_ssh_bridge.sh` | Provision temp user + key on target, register Bridge session |
| `checkin_ssh_bridge.sh`  | Terminate Bridge session, deprovision key/sudoers (optionally the user) |

---

## How the user connects

The checkout returns everything needed:

```
ssh -p 2222 -l '<email>%<target-host>' <bridge-host>
```

The username is passed with `-l` (not `user@host`) because it contains both
`@` (the email) and `%` (the target separator) — embedding it before the host
would be ambiguous to the ssh client.

- **Host / port** — `BRIDGE_URL:NATIVE_PORT`, the Bridge's native SSH listener
  (`2222` by default — the port the ECS deployment's NLB exposes for SSH), not
  the target. One NLB fronts both the web tier and every native listener, so the
  browser session and the native ssh client use the **same host**.
- **Username** — `<email>%<target-host>` where `<email>` is the user's Britive
  identity (`BRITIVE_USER_EMAIL`). The Bridge matches this against the
  checkout's owner to route the session — it must equal the checkout owner /
  SSO identity, **not** the profile "Bridge Username" field.
- **Password** — the Bridge Password from the user's Britive profile
  (`BRIDGE_AUTH_PASSWORD`), registered on the checkout; the user types it at the
  ssh password prompt.
- **Key auth (optional)** — when `BRIDGE_AUTH_PUBKEY` is set (a Bridge SSH Key
  on the profile), it is added as `user_public_key` so the user may
  authenticate with their own private key in addition to the password.
  `bridge_auth_password` is always registered — the Bridge requires it.
  `auth_method` in the output reports `pubkey` (key available) vs `password`.
- **Browser** — `{{browser_session}}` opens the in-browser terminal
  (`https://<bridge-host>/ssh/#transaction_id=<TRX>`).

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
|----------|-------------|
| `BRITIVE_USER_EMAIL` | Requesting user's email — local part becomes the Linux username |
| `TRX` | Britive transaction ID for this checkout |
| `TARGET_HOST` | Hostname or IP of the SSH target |
| `BRIDGE_URL` | Bridge hostname — one NLB serves both browser and native sessions, e.g. `bridge.example.com` — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |
| `BRIDGE_AUTH_PASSWORD` | Bridge password from the profile; broker-injected. **Always required** — the Bridge rejects a `bridge_credentials` checkout without it. The native login username is the user's email (`BRITIVE_USER_EMAIL`), not a separate bridge username |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `BRIDGE_AUTH_PUBKEY` | — | User's SSH **public** key from the profile Bridge SSH Key. When set, added as `user_public_key` so the user may authenticate with their own private key in addition to the password |
| `TARGET_PORT` | `22` | SSH port on the target |
| `NATIVE_PORT` | `2222` | Port of the Bridge's native SSH listener |
| `BRITIVE_SUDO` | `0` | `1` grants the temp user passwordless sudo |
| `PROVISION_USER` | `britivebroker` | Privileged account used to provision the target |
| `PROVISION_HOST` | `TARGET_HOST` | Override if provisioning host differs |
| `PROVISION_PORT` | `TARGET_PORT` | SSH port for provisioning |
| `PROVISION_KEY` | `/home/bridge/.ssh/id_ed25519` | Path to the provisioning private key |
| `PROVISION_KEY_PEM` | — | Inline PEM key content (preferred; written to tmpfs) |
| `DELETE_USER` | `0` | **Checkin only** — `1` deletes the temp user account and home dir |
| `BROKER_API` | `/opt/britive-broker/scripts/broker-bridge-api.sh` | Path to the Bridge API helper CLI |

---

## How It Works

### Checkout (`checkout_ssh_bridge.sh`)

1. Derives the Linux username from the user's email (local part, alphanumeric only).
2. Generates a one-time `ed25519` keypair tagged `bridge:<TRX>`.
3. SSHes to the target as `PROVISION_USER` and: creates the user if missing,
   installs the public key, optionally writes `/etc/sudoers.d/bridge-<TRX>`.
4. Registers an `ssh` checkout with the Bridge
   (`broker-bridge-api.sh checkout-create`) carrying the private key, expiry,
   and the bridge credential (`native_auth=bridge_credentials` +
   `bridge_auth_password`, plus `user_public_key` when `BRIDGE_AUTH_PUBKEY` is
   set). If registration fails, the provisioned key/sudoers entry is rolled back.
5. Returns JSON in the standard Bridge checkout schema (same keys as the
   MySQL and Windows RDP bridge checkouts, so one response template covers
   all of them):

   ```json
   {
     "BRIDGE_URL": "bridge.example.com",
     "command": "ssh -p 2222 -l 'alice@corp%server.internal' bridge.example.com",
     "auth_method": "password",
     "bridge_username": "alice@corp%server.internal",
     "bridge_port": "2222",
     "target_username": "alicecorp",
     "browser_session": "https://bridge.example.com/ssh/#transaction_id=<TRX>"
   }
   ```

   Surface `{{command}}` and `{{bridge_username}}` in the response template;
   with `auth_method=password` the user types the Bridge Password from their
   profile at the ssh prompt, with `auth_method=pubkey` no password is needed.
   `{{browser_session}}` opens the in-browser terminal.

### Checkin (`checkin_ssh_bridge.sh`)

1. Deletes the Bridge checkout (`broker-bridge-api.sh checkout-delete <TRX>`)
   **first** — revokes the proxy credential and terminates any live session.
2. SSHes to the target and removes the key matching `bridge:<TRX>` and the
   sudoers entry. With `DELETE_USER=1`, also removes the account and home dir.

---

## Bridge Requirements

Native SSH mode must be enabled on the Bridge (off by default):

```yaml
ssh:
  idle_timeout: 30m
  native:
    enabled: true
    listen: "2222"
  browser:
    enabled: true
```

Set `BRIDGE_HOST_KEY_SEED` (or `ssh.native.host_key_seed`) in clustered
deployments so every session worker presents the same host key fingerprint —
the ECS CloudFormation template's `HostKeySeed` parameter handles this.

The Bridge needs network reachability to the target on `TARGET_PORT`, and users
must be able to reach the Bridge on `NATIVE_PORT` (ECS NLB exposes `2222`).

---

## Target Host Requirements

- `PROVISION_USER` must have **passwordless sudo** (or be root) on the target.
- The provisioning key must be in `~<PROVISION_USER>/.ssh/authorized_keys`.
- Standard utilities: `sh`, `id`, `useradd`/`adduser`, `mkdir`, `chmod`,
  `chown`, `grep`, `tee`, `base64`.

## Broker Container Requirements

- `ssh`, `ssh-keygen`, `base64`, `jq`
- `broker-bridge-api.sh` at `BROKER_API` path

---

## Security Notes

- The one-time private key is generated at checkout, passed to the Bridge as
  `private_key`, and never returned to the user.
- The bridge password (`BRIDGE_AUTH_PASSWORD`) comes from the user's Britive
  profile via the broker and is always registered on the checkout as
  `bridge_auth_password` (the Bridge requires it); an optional
  `BRIDGE_AUTH_PUBKEY` is added as `user_public_key`. The checkout dies with the
  transaction on checkin or expiry.
- Add `allowed_commands` / `blocked_patterns` to the payload for command
  guardrails — but remember command filtering is an audit aid, **not** a
  security control.
