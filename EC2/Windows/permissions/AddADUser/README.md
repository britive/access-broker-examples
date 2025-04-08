# Active Directory Just-in-Time Access for Windows Servers via AWS SSM

This project provides a secure, auditable, and automated way to grant **just-in-time (JIT)** administrative access to Windows servers for **Active Directory users** using **AWS Systems Manager (SSM)**. It replaces the need to manage local accounts by temporarily adding AD users to the `Administrators` group and removing them after use.

## 📂 Components

### 1. `AddLocalAdminADUser.json`
An SSM document that:
- Accepts a domain username as input
- Adds the user to the `Administrators` group on the target Windows EC2 instance

### 2. `RemoveLocalADUser.json`
An SSM document that:
- Accepts the domain username
- Removes the user from the `Administrators` group
- Optionally logs them out if a session is active

## 🚀 Deployment

Use the following AWS CLI commands to create the documents:

```bash
aws ssm create-document \
  --name "AddLocalAdminADUser" \
  --document-type "Command" \
  --document-format "JSON" \
  --content file://AddLocalAdminADUser.json

aws ssm create-document \
  --name "RemoveLocalADUser" \
  --document-type "Command" \
  --document-format "JSON" \
  --content file://RemoveLocalADUser.json
```


## ✅ Benefits of Using SSM Proxy

- **No RDP exposure:** No need to open port 3389 to the world.
- **Credentialless access:** SSM operates using instance IAM roles, eliminating static credentials.
- **Auditability:** All command executions are logged in AWS CloudTrail and optionally in SSM Session Manager logs.
- **Granular control:** Commands can be scoped per user, per group, or with approval flows using systems like Britive or Slack chatbots.
- **Cross-platform support:** Works similarly across EC2, hybrid on-prem, and cloud-hosted Windows machines.


## 🔐 Security Considerations

- **IAM Policies:** Ensure only approved users can invoke the SSM documents.
- **SSM Logging:** Enable session and command logging in Amazon S3 and CloudWatch for audit trails.
- **Role Assumption:** Integrate with platforms like Britive for ephemeral role assumption and temporary access credentials.
- **Cleanup Enforcement:** Always pair access grants with scheduled removal via automation or user-driven triggers.
- **Domain Trust:** Ensure the instance and user are joined to the same AD domain or trust.


## 🧠 Extensibility Ideas

- Slack chatbot integration for on-demand RDP access
- Scheduled cleanup via Lambda or Step Functions
- Role-based dashboards with audit history
- Multi-user access controls per project or app team


## 🛠 Prerequisites

- EC2 Windows instances with SSM Agent and domain-joined
- Proper IAM roles for EC2 and calling identity
- AWS CLI and access credentials
- Optional: Britive or your JIT access broker


## 🙌 Acknowledgements

This project builds on AWS Systems Manager, AD group policies, and best practices for ephemeral access management.

