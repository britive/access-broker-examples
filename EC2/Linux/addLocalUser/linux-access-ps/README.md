# Britive SSH Access Script (PowerShell)

This script automates **just-in-time SSH access** to EC2 instances using AWS Systems Manager (SSM). It creates a temporary SSH key pair, sends the public key to the target EC2 instance via an SSM document, and optionally grants `sudo` access. The private key is output to the console (and can optionally be converted to PuTTY `.ppk` format).

---

## 🚀 Features

- Creates a temporary Linux user with SSH key-based access.
- Supports access with or without `sudo` privileges.
- Automatically removes the user on check-in.
- Converts the private key to PuTTY `.ppk` format if PuTTYgen is installed.

---

## 🧰 Prerequisites

### ✅ AWS Requirements

- An EC2 instance with:
  - AWS SSM Agent installed and running.
  - IAM Role attached with at least the following permissions:
    - `ssm:SendCommand`
    - `ssm:ListCommandInvocations`
  - SSM Document named `addSSHKey` and `removeSSHKey` defined and accessible.

- AWS CLI installed and configured with:
  - Access key/secret pair via environment or profile
  - (If not deployed on EC2 instance) `aws configure` or environment variables:

    ```powershell
    $env:AWS_ACCESS_KEY_ID = "<your-access-key>"
    $env:AWS_SECRET_ACCESS_KEY = "<your-secret-key>"
    $env:AWS_DEFAULT_REGION = "us-west-2"
    ```

---

### ✅ PowerShell Environment

- PowerShell 5.1+ (Windows) or PowerShell Core (cross-platform)

#### Required PowerShell Tools

| Tool          | Usage                                  | Install Instructions                                     |
|---------------|----------------------------------------|----------------------------------------------------------|
| `ssh-keygen`  | Generates SSH key pair                 | Comes with Git Bash or OpenSSH on Windows                |
| `aws` CLI     | Sends SSM commands                     | [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| `puttygen.exe`| Converts PEM to `.ppk` for PuTTY users | [Download PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) and add `puttygen.exe` to your PATH |

---

## 🔧 Environment Variables

The script reads configuration from environment variables:

| Variable             | Description                                     |
|----------------------|-------------------------------------------------|
| `BRITIVE_ACTION`     | `checkout` to create user, `checkin` to remove  |
| `INSTANCE`           | EC2 instance ID                                 |
| `BRITIVE_SUDO`       | `1` to grant sudo access, `0` otherwise         |
| `BRITIVE_USER_EMAIL` | User’s email (used to derive username)          |

Example:

```powershell
$env:BRITIVE_ACTION = "checkout"
$env:INSTANCE = "i-0abc8"
$env:BRITIVE_SUDO = "1"
$env:BRITIVE_USER_EMAIL = "alice@example.com"
````

---

## 🛠️ Usage

### Checkout (Grant Access)

```powershell
.\britive-ssh.ps1
```

Outputs the SSH private key (PEM format) to the console.

Optional `.ppk` conversion if `puttygen.exe` is found.

---

### Checkin (Remove Access)

```powershell
$env:BRITIVE_ACTION = "checkin"
.\britive-ssh.ps1
```

Removes the temporary user from the instance via `removeSSHKey` SSM document.

---

## 🧪 Troubleshooting

- If you see:
  `Write-Error: Failed to send command`
  → Check your AWS credentials and IAM permissions.

- If `.ppk` conversion is skipped:
  → Ensure `puttygen.exe` is in your system PATH.

- If SSM command hangs:
  → Confirm the EC2 instance is online, has SSM agent running, and is properly tagged.

---

## 📁 Output

- Private Key: Printed to console (e.g., `britive-id_rsa`)
- Public Key: Injected into EC2 via SSM
- Optional `.ppk`: If PuTTYgen is found

---

## 📌 Notes

* This script is designed to be used in secure automation pipelines or called by a privileged automation platform (e.g., Britive).
* Ensure the EC2 instance has outbound internet access or a VPC endpoint to connect to SSM.

---

## 🔐 Security Warning

**Never store or log the private key unless absolutely necessary.**
Access to this key should be tightly controlled and short-lived.
