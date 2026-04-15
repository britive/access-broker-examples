# temp-ssh-key-remote-bridge

Checkout / checkin scripts for JIT SSH access via the **Britive bridge platform**.

On checkout, a one-time `ed25519` keypair is generated, the public key is provisioned
on the target host, and a proxied SSH session is registered with the bridge.
The user receives a browser-accessible URL instead of a raw private key.
On checkin, the key is removed, the sudoers entry (if any) is cleaned up, and the
bridge session is terminated.

---

## Files

| File | Purpose |
|------|---------|
| `checkout_remote_bridge.sh` | Provision target host + register bridge session |
| `checkin_remote_bridge.sh`  | Deprovision target host + terminate bridge session |

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
|----------|-------------|
| `BRITIVE_USER_EMAIL` | Britive user email — local part becomes the OS username |
| `TRX` | Britive transaction ID for this checkout |
| `BRITIVE_REMOTE_HOST` | Hostname or IP of the SSH target |
| `BRIDGE_URL` | Public base URL of the bridge (e.g. `https://bridge.example.com`) — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `REMOTE_USER` | `britivebroker` | Privileged account used by the broker to connect to the target |
| `PROVISION_HOST` | `BRITIVE_REMOTE_HOST` | Override if the provisioning host differs from the target |
| `PROVISION_PORT` | `22` | SSH port on the provisioning host |
| `PROVISION_KEY` | `/home/bridge/.ssh/id_ed25519` | Broker's private key for provisioning connections |
| `BRITIVE_SUDO` | `0` | Set to `1` to grant the target user passwordless sudo |
| `BROKER_API` | `/opt/britive-broker/scripts/bridge.sh` | Path to the bridge CLI |

---

## How It Works

### Checkout (`checkout_remote_bridge.sh`)

1. Derives the OS username from `BRITIVE_USER_EMAIL` (local part, alphanumeric only).
2. Generates a one-time `ed25519` keypair tagged `bridge:<TRX>`.
3. Opens a single SSH connection to the target host (as `REMOTE_USER`) and:
   - Creates the target user if it does not exist.
   - Appends the public key to `~<user>/.ssh/authorized_keys`.
   - Optionally writes a passwordless sudoers entry under `/etc/sudoers.d/bridge-<TRX>`.
4. Calls `bridge.sh checkout-create` with a JSON payload containing the private key,
   session token, and expiry.
5. Returns:

   ```json
   {"token": "<token>", "url": "https://bridge.example.com/ssh/#token=<token>&transaction_id=<TRX>"}
   ```

### Checkin (`checkin_remote_bridge.sh`)

1. Opens an SSH connection to the target host and:
   - Removes the key matching `bridge:<TRX>` from `authorized_keys`.
   - Removes `/etc/sudoers.d/bridge-<TRX>` if sudo was granted.
2. Calls `bridge.sh checkout-delete --transaction-id <TRX>` to close the bridge session.

---

## Target Host Requirements

- The `REMOTE_USER` account (`britivebroker`) must have **passwordless sudo** on the target,
  or be running as root.
- The broker container's key (`/home/bridge/.ssh/id_ed25519`) must be in the target's
  `~britivebroker/.ssh/authorized_keys`.
- Standard utilities: `sh`, `id`, `useradd`/`adduser`, `mkdir`, `chmod`, `chown`, `grep`, `tee`.

---

## Broker Container Requirements

- `ssh`, `ssh-keygen`, `base64`, `python3`
- `bridge.sh` at `BROKER_API` path (default `/opt/britive-broker/scripts/bridge.sh`)

---

## Optional: Delete User on Checkin

The user deletion block in `checkin_remote_bridge.sh` is commented out by default.
Uncomment and set `DELETE_USER=1` if the target user should be removed after every session.
