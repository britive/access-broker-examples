# temp-user-bridge (Linux SSH)

Checkout / checkin scripts for JIT Linux SSH access **proxied through the Britive
Bridge (v2)**.

On checkout, a temporary Linux user is provisioned on the target with a one-time
`ed25519` key (used only by the Bridge to reach the target), and an `ssh`
checkout is registered with the Bridge. The user connects with their **local
`ssh` client on their workstation**, pointed at the Bridge's native SSH
listener, and authenticates with a **per-checkout Bridge password** — or opens
the in-browser terminal. The private key never leaves the broker/Bridge, and
the session is fully brokered and recorded.

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
ssh -p 2222 '<email>%<target-host>'@<bridge-host>
```

- **Host / port** — the Bridge's native SSH listener (`2222` by default — the
  port the ECS deployment's NLB exposes for SSH), not the target.
- **Username** — `<bridge-user>%<target-host>` so the Bridge can match the
  checkout and route the session to the approved target.
- **Password** — the per-checkout Bridge password from the checkout response
  (`bridge_credentials` mode). With `NATIVE_AUTH=ldap` the user enters their
  own directory password instead.
- **Key auth (optional)** — set `USER_PUBLIC_KEY` to the user's own SSH public
  key and they can authenticate to the Bridge with their keypair instead of a
  password.
- **Browser** — `{{url}}` opens the in-browser terminal
  (`/connect?transaction_id=<TRX>`).

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
|----------|-------------|
| `BRITIVE_USER_EMAIL` | Requesting user's email — local part becomes the Linux username |
| `TRX` | Britive transaction ID for this checkout |
| `TARGET_HOST` | Hostname or IP of the SSH target |
| `BRIDGE_URL` | Public base URL of the Bridge (e.g. `https://bridge.example.com`) — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET_PORT` | `22` | SSH port on the target |
| `NATIVE_PORT` | `2222` | Port of the Bridge's native SSH listener |
| `NATIVE_AUTH` | `bridge_credentials` | `bridge_credentials` (generated password) or `ldap` (directory password) |
| `USER_PUBLIC_KEY` | — | User's own SSH public key for key auth to the Bridge |
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
   (`broker-bridge-api.sh checkout-create`) carrying the private key,
   `native_auth` settings, and expiry. If registration fails, the provisioned
   key/sudoers entry is rolled back.
5. Returns JSON for the response template:

   ```json
   {
     "token": "<token>",
     "url": "https://bridge.example.com/connect?transaction_id=<TRX>",
     "ssh_command": "ssh -p 2222 'alice@corp%server.internal'@bridge.example.com",
     "bridge_username": "alice@corp%server.internal",
     "bridge_password": "<generated>",
     "bridge_host": "bridge.example.com",
     "bridge_port": "2222",
     "target_username": "alicecorp"
   }
   ```

   Surface `{{ssh_command}}` and `{{bridge_password}}` in the response
   template; `{{url}}` for the browser terminal.

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
- The Bridge password is per-checkout and dies with the transaction on checkin
  or expiry.
- Add `allowed_commands` / `blocked_patterns` to the payload for command
  guardrails — but remember command filtering is an audit aid, **not** a
  security control.
