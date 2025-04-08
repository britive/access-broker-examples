
---

## 📘 Project Summary

This project provides a secure, auditable, and automated method to manage local administrative access on EC2 Windows instances using AWS Systems Manager (SSM). It includes:

- `CreateLocalAdminUser.json`: An SSM document to **provision a local admin account** with a specified password.
- `RemoveLocalUser.json`: An SSM document to **delete a local user account** from a Windows instance.
- `ec2-windows-admin.sh`: A helper script to **interact with the SSM documents** using AWS CLI—supporting just-in-time access provisioning and cleanup.

By leveraging SSM and role-based access through Britive, access is ephemeral, tightly controlled, and fully logged.

---

## 📄 README

### 📂 Files Included

| File                        | Purpose                                                                  |
|-----------------------------|--------------------------------------------------------------------------|
| `CreateLocalAdminUser.json` | SSM document to create a new local admin user on a Windows EC2 instance  |
| `RemoveLocalUser.json`      | SSM document to remove a local user from a Windows EC2 instance          |
| `ec2-windows-admin.sh`      | Bash script to execute the above SSM documents using AWS CLI             |

---

### 🛠️ Prerequisites

- Britive Broker installed on an EC2 instance
- AWS CLI configured with right roles for the EC2 instance running the Britive broker
- IAM permissions to run `ssm:SendCommand`
- EC2 instances:
  - Running Windows Server
  - SSM agent installed and running
  - Managed by AWS Systems Manager
- For just-in-time access: [Britive](https://docs.britive.com/docs/overview-accessbroker) for temporary credential injection
- (Optional) [Slack chatbot](https://docs.britive.com/docs/configuring-slack-app) integration for interactive access requests

---

### 🚀 Usage

#### ✅ Create Local Admin User

```bash
aws ssm send-command \
  --document-name "CreateLocalAdminUser" \
  --targets "Key=instanceIds,Values=i-0abc123456789xyz0" \
  --parameters '{"username":["exampleuser"],"password":["ComplexP@ss123"]}' \
  --comment "JIT access provisioning" \
  --region us-west-2
```

> Automatically adds the user to the `Administrators` group.

---

#### ❌ Remove Local User

```bash
aws ssm send-command \
  --document-name "RemoveLocalUser" \
  --targets "Key=instanceIds,Values=i-0abc123456789xyz0" \
  --parameters '{"username":["exampleuser"]}' \
  --comment "Cleanup user access" \
  --region us-west-2
```

> Optionally extend to forcibly log out user before removal.

---

### 🧠 Enhancements

- Integration with Britive for temporary credentials
- Scheduled cleanup via CloudWatch Events
- Slack bot to initiate and expire access dynamically
- Optional: Add forced logoff before removal using:

  ```powershell
  logoff (query session | findstr "{{username}}" | foreach { ($_ -split '\s+')[2] })
  ```

---

## 🧰 Benefits of Using SSM Proxy

- ✅ **No SSH/RDP required**: Operates entirely over SSM agent; avoids exposing ports.
- 🔐 **Secure by design**: Credentials stay in AWS, optionally delivered by Britive.
- 📜 **Auditable actions**: All SSM commands are logged in CloudTrail.
- 🎯 **Granular control**: IAM and Britive manage who can run commands and when.
- 🔄 **Automation ready**: Easily integrate into CI/CD, GitOps, or incident response pipelines.

---

## 🔐 Security Considerations

1. **Temporary Credentials**: Use ephemeral credentials (via Britive or STS) to avoid long-lived secrets.
2. **Document Permissions**: Restrict who can execute the SSM documents.
3. **Password Handling**:
   - Avoid hardcoding.
   - Use random complex password generation (via script or Secrets Manager).
4. **Session Expiry**: Automatically remove users or expire access after predefined durations.
5. **Logging & Alerts**:
   - Use CloudTrail, CloudWatch Logs, and EventBridge for real-time monitoring and alerting.
6. **No External Exposure**: Ensure no inbound RDP ports are open. Use Session Manager port forwarding if RDP is necessary.

---
