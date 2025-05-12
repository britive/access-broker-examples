
---

## 🔐 Just-In-Time SSH Access for EC2 Linux Instances via AWS SSM

This solution provides two AWS SSM documents to enable **secure, on-demand SSH access** to Linux EC2 instances using a temporary user and injected SSH public key. It supports automation workflows including **Britive**, **Slack chatbot triggers**, and **scheduled cleanup**.

---

## 📄 Documents Overview

### 1. `SsmSshKey`
Creates a Linux user (if it doesn’t exist), injects the specified SSH public key, and grants **passwordless sudo access**.

### 2. `SsmRemoveSshKey`
Deletes the previously created Linux user, their home directory, SSH keys, and any sudoers configuration.

---

## ⚙️ Usage

### 📌 Prerequisites

- Target EC2 Linux instances must have the **SSM agent installed and running**
- IAM instance role must allow `ssm:SendCommand`
- Your CLI user/role must be allowed to run SSM documents
- SSH port (22) must be open to your bastion or through SSM port forwarding

---

## 🛠️ Inject SSH Public Key (SSM-InjectSshKey)

### 📝 Document Parameters:

| Name         | Type   | Description                             |
|--------------|--------|-----------------------------------------|
| `username`   | String | Username to create or configure         |
| `sshPublicKey` | String | SSH public key to inject into authorized_keys |

### ✅ Example:

```bash
aws ssm send-command \
  --document-name "SSM-InjectSshKey" \
  --targets "Key=InstanceIds,Values=i-0123456789abcdef0" \
  --parameters '{
    "username": ["jituser"],
    "sshPublicKey": ["ssh-ed25519 AAAAC3NzaC1... user@example.com"]
  }' \
  --region us-east-1
```

This:
- Adds `jituser` if not present
- Injects the specified public key into `/home/jituser/.ssh/authorized_keys`
- Grants passwordless sudo access to `jituser`

---

## 🧹 Remove Linux User (SSM-RemoveLocalUser)

### 📝 Document Parameters:

| Name         | Type   | Description                  |
|--------------|--------|------------------------------|
| `username`   | String | Username to remove completely |

### ✅ Example:

```bash
aws ssm send-command \
  --document-name "SSM-RemoveLocalUser" \
  --targets "Key=InstanceIds,Values=i-0123456789abcdef0" \
  --parameters '{
    "username": ["jituser"]
  }' \
  --region us-east-1
```

This:
- Kills any running processes of the user
- Deletes the user and their home directory
- Removes `/etc/sudoers.d/<username>` entry

---

## ✅ Benefits

- No permanent credentials on hosts
- Just-in-time access with minimal blast radius
- Easily triggered from CI/CD, Slack, or Britive
- Works across multiple EC2s without direct SSH access

---

## 💡 Example Use Case Flow

1. **Britive** grants temporary IAM role access with `ssm:SendCommand` permission.
2. **Slack chatbot** sends the public key and target instance ID to AWS.
3. **SSM document** runs to create the user and inject the key.
4. Access is granted for a limited time.
5. **Cleanup script** (or scheduled EventBridge rule) runs `SSM-RemoveLocalUser`.

---




  
// This document is used to remove a local Linux user, their SSH keys, and sudo access.
// It first checks if the user exists, and if so, it removes the user and their home directory.
// It also removes any sudo access by deleting the corresponding file in /etc/sudoers.d.
// The script uses the `pkill` command to terminate any processes owned by the user before deletion.
// The `|| true` part ensures that the script continues even if the command fails, which is useful for optional cleanup tasks.
// The script is designed to be run with elevated privileges, so it uses `sudo` for commands that require root access.
// The `set -e` command ensures that the script exits immediately if any command fails, which is a good practice for scripts that modify system state.  