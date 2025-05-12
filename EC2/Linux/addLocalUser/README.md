# EC2 Just-In-Time SSH Access with SSM and Britive

This project provides a lightweight mechanism for Just-In-Time (JIT) SSH access to EC2 instances using AWS SSM documents, triggered via a shell script integrated with Britive.

## 📦 Components

### 1. `addSSHKey.json`
SSM document that:
- Creates a Linux user if not present.
- Generates an SSH key pair (`britive-id_rsa`) on the target EC2.
- Adds the public key to `authorized_keys`.
- Optionally grants sudo access.
- Outputs the private key for secure temporary access.

### 2. `removeSSHKey.json`
SSM document that:
- Deletes a Linux user, their SSH keys, and sudoers entry if present.

### 3. `ec2-ssh-user.sh`
Shell script that:
- Reads user information and intent from environment variables (`BRITIVE_*`).
- Uses `aws ssm send-command` to run either `addSSHKey` or `removeSSHKey` on the target EC2 instance.
- Integrates with the Britive platform’s checkout/checkin workflows.

## 🚀 Usage

### Prermission Variables Required on Britive

| Variable           | Purpose                             |
|--------------------|--------------------------------------|
| `BRITIVE_ACTION`   | `checkout` or `checkin`             |
| `INSTANCE`         | EC2 Instance ID                     |
| `BRITIVE_USER_EMAIL` | Email address of the accessing user |
| `BRITIVE_SUDO`     | Set to `1` to enable sudo access    |

### Create SSM Documents

```bash
aws ssm create-document \
  --name "addSSHKey" \
  --document-type "Command" \
  --document-format "JSON" \
  --content file://addSSHKey.json \
  --region us-west-2
```

```bash
aws ssm create-document \
  --name "removeSSHKey" \
  --document-type "Command" \
  --document-format "JSON" \
  --content file://removeSSHKey.json \
  --region us-west-2

```
Optionally make this document available across all account ids.

```bash
aws ssm modify-document-permission \
  --name "addSSHKey" \
  --permission-type Share \
  --account-ids all \
  --region us-west-2
```


### Expected Behavior
- **checkout**: Adds the user and returns an SSH private key.
- **checkin**: Removes the user and cleans up access.

## ✅ Prerequisites

- EC2 instance must have the **SSM agent running** and **IAM role allowing SSM access**.
- Broker shell environment must be configured with AWS CLI.
- Ensure IAM permissions to use `ssm:SendCommand`, `ssm:GetCommandInvocation`, etc.

## 🔐 Security Notes

- The private key is returned via SSM output. Handle with care.
- Temporary access is revoked by deleting the user via `removeSSHKey`.

## 📁 File Summary

| File               | Purpose                        |
|--------------------|--------------------------------|
| `addSSHKey.json`   | Adds user + SSH key            |
| `removeSSHKey.json`| Removes user + key             |
| `ec2-ssh-user.sh`  | Executes SSM commands via CLI  |

---
