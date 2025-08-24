# Britive Temporary SSH Access Scripts

This directory contains shell scripts to manage **ephemeral SSH access** for Linux servers.  
The scripts create and remove SSH keys in user `authorized_keys`, optionally grant **sudo** access, and can operate with or without a **Transaction ID (TRX)** for fine-grained key management.

---

## 📂 Scripts Overview

### 1. Create Access (without britive trx id)

- **File:** `checkout.sh`
- Adds a user's SSH public key to their `~/.ssh/authorized_keys`.
- Grants `sudo` access if `BRITIVE_SUDO=1`.
- Identifies user based on `BRITIVE_USER_EMAIL`.

### 2. Remove Access (without britive trx id)

- **File:** `checkin.sh`
- Removes a user’s SSH public key from `authorized_keys`.
- Deletes the sudoers file if present.
- Cleans up the user’s access fully.

---

### 3. Create Access with TRX

- **File:** `checkout_with_trx_id.sh`
- Same as `checkout.sh`, but tags the SSH key with a `trx=<ID>` comment.
- Supports multiple concurrent access grants for the same user.
- Controlled by the `TRX` environment variable.

Example entry in `authorized_keys`:

``` bash
ssh-rsa AAAAB3... [user@example.com](mailto:user@example.com) trx=FsknubAidfdploRdj

```

### 4. Remove Access with TRX

- **File:** `checkin_with_trx_id.sh`
- Removes only the key associated with a given `TRX` for the user.
- Leaves other keys (different TRX values) intact.
- Deletes sudoers entry if present.

---

## ⚙️ Environment Variables

| Variable             | Purpose                                                                 |
|----------------------|-------------------------------------------------------------------------|
| `BRITIVE_USER_EMAIL` | Email of the user requesting access (e.g., `johndoe@example.com`).         |
| `BRITIVE_SUDO`       | `1` = grant sudo privileges, `0` = no sudo.                             |
| `BRITIVE_HOME_ROOT`  | Base path for home directories (default: `home`).                       |
| `TRX`                | Transaction ID of the profile checkout to tag/remove specific keys (used only in TRX scripts).  |

---

## Test Examples

### Grant Access (original)

```bash
export BRITIVE_USER_EMAIL="alice@example.com"
export BRITIVE_SUDO=1
bash checkout.sh
````

### Revoke Access (original)

```bash
export BRITIVE_USER_EMAIL="alice@example.com"
bash checkin.sh
```

---

### Grant Access with TRX

```bash
export BRITIVE_USER_EMAIL="alice@example.com"
export BRITIVE_SUDO=1
export TRX="session-12345"
bash checkout_with_trx_id.sh
```

### Revoke Access with TRX

```bash
export BRITIVE_USER_EMAIL="alice@example.com"
export TRX="session-12345"
bash checkin_with_trx_id.sh
```

---

## Notes

- These scripts must be executed with sufficient privileges (root or via `sudo`).
- The TRX-enabled scripts are safer for multi-session environments, since they only remove the matching key.
- When no TRX is used, all keys for the user are affected.

---
