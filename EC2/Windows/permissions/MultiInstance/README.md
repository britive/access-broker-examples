
````markdown
# 🔐 Just-in-Time Windows Admin Access via AWS SSM

This Python script provides a secure, automated way to manage **just-in-time administrative access** to Windows EC2 instances using **AWS Systems Manager (SSM)**. It grants or revokes access for Active Directory users by adding or removing them from the local `Administrators` group via pre-defined SSM documents.

---

## 📦 Features

- ✅ Grants Windows admin access via AD user membership injection
- ✅ Revokes access cleanly and logs out active sessions
- 🔒 No need to open RDP ports — everything runs through SSM
- 🧩 Targets instances dynamically using EC2 tags
- 📜 Fully auditable in CloudTrail and SSM logs

---

## 🛠 Requirements

- Python 3.11+
- AWS credentials (via `~/.aws/credentials`, environment variables, or assumed role for the instance)
- AWS SSM documents:
  - `AddLocalAdminADUser`
  - `RemoveLocalADUser`
- EC2 instances:
  - Must be **SSM managed**
  - Must be **domain-joined**
  - Must be tagged appropriately

---

## 🚀 Usage

### 1. Set Required Environment Variables (TESTING)

```bash
export JIT_TAG_KEY="AccessGroup"
export JIT_TAG_VALUES="JITAdmins,OnCall"
export USER="corp\\jdoe"
````

### 2. Grant (Checkout) Access

```bash
export JIT_ACTION="checkout"
python jit_access.py
```

> ✅ Adds the AD user `corp\jdoe` to the local Administrators group on all matching instances.

---

### 3. Revoke (Check-in) Access

```bash
export JIT_ACTION="checkin"
python jit_access.py
```

> 🧹 Removes the AD user from the Administrators group and logs out any active sessions.

---

## 🌐 Environment Variables

| Variable         | Description                                                              | Required   |
| ---------------- | ------------------------------------------------------------------------ |------------|
| `JIT_TAG_KEY`    | The EC2 tag key to filter target instances                               | ✅         |
| `JIT_TAG_VALUES` | Comma-separated values for the tag (e.g. `"JITAdmins,Prod"`)             | ✅         |
| `USER`           | The domain-qualified AD username (e.g. `corp\\jdoe`)                     | ✅         |
| `JIT_ACTION`     | `"checkout"` to grant access, `"checkin"` to revoke (default: `"grant"`) | ✅         |

---

## 🔐 Security Notes

* All access is temporary and tied to AD credentials
* SSM activity is logged in AWS CloudTrail
* No need to expose or rotate passwords or SSH keys
* Compatible with access brokers like Britive for role assumption

---
