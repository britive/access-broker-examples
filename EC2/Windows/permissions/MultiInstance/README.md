# 🔐 Just-in-Time Windows Admin Access via AWS SSM

This Python script provides secure, auditable, and dynamic **just-in-time administrative access** to Windows EC2 instances using **AWS Systems Manager (SSM)**. It grants or revokes Active Directory user access to the `Administrators` group based on EC2 instance tags using a single JSON input.

---

## 📦 Features

- ✅ Grants or revokes Windows admin access via AWS SSM documents
- 🔐 Uses Active Directory usernames (no local password management)
- 🧩 Dynamically targets instances using multiple EC2 tags with AND conditions
- 🧾 Supports a single JSON input for tag filters (cleaner and more portable)
- 🛡 Secure and auditable — no need to open RDP ports

---

## 🛠 Requirements

- Python 3.11+
- AWS credentials configured (CLI, environment, or assumed role)
- EC2 instances:
  - Must be domain-joined
  - Must be SSM-managed
  - Must be tagged with filters defined in `JIT_TAGS`
- Two AWS SSM documents must exist:
  - `AddLocalAdminADUser`
  - `RemoveLocalADUser`

---

## 🚀 Usage

### 1. Define Access Parameters

```bash
export JIT_TAGS='{"Environment": "Prod", "Team": "DevOps,Platform"}'
export USER="CORP\\jdoe"
````

### 2. Grant Access (Checkout)

```bash
export JIT_ACTION="checkout"
python jit_access.py
```

> ✅ This will add the user `CORP\jdoe` to the `Administrators` group on all Windows EC2 instances matching:
>
> * `Environment = Prod`
> * AND `Team` in `[DevOps, Platform]`

---

### 3. Revoke Access (Check-in)

```bash
export JIT_ACTION="checkin"
python jit_access.py
```

> 🧹 This will remove the user `CORP\jdoe` from the `Administrators` group on those instances.

---

## 🌐 Environment Variables

| Variable     | Description                                                                      |
| ------------ | -------------------------------------------------------------------------------- |
| `JIT_TAGS`   | JSON string of EC2 tag filters. Values can be CSV strings. Required.             |
| `USER`       | Domain-qualified AD username (e.g., `CORP\\jdoe`). Required.                     |
| `JIT_ACTION` | `checkout` to grant access, `checkin` to revoke. Optional (default: `checkout`). |

---

## 🔐 Security Notes

* All commands are issued over the SSM channel (no open ports required)
* Actions are logged in AWS CloudTrail
* Ephemeral access enables enforcement of least-privilege principles
* Can be integrated with Britive or IAM role assumption for secure dispatch

---

## 🧠 Extensibility Ideas

* 🕒 Schedule automatic revocation after N minutes using EventBridge + Lambda
* 📢 Notify via Slack, Teams, or email when access is granted or revoked
* 🔍 Store command and session activity in DynamoDB for audit tracking
* 💼 Support bulk actions or group roles

---