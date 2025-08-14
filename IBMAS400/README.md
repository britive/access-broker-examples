
# AS400 Access Automation with Britive

**DRAFT SCRIPTS**

## Overview

This toolkit allows you to create and remove short-lived IBM i (AS400) accounts using Britive automation.
It supports three automation options:

1. **Primary** – PowerShell with IBM Access Client Solutions (ACS) `system` command.
2. **Backup #1** – PowerShell with SSH.
3. **Backup #2** – Bash with SSH.

Britive will handle time-based account expiry. These scripts simply create and remove users based on environment variables passed at runtime.

---

## Prerequisites

### Common

- Britive configured to pass required environment variables:
  - `AS400_HOST` – Hostname or IP of the AS400.
  - `AS400_ADMIN_USER` – Admin username with authority to manage users.
  - `AS400_ADMIN_PASS` – Admin password.
  - `AS400_NEW_USER` – User ID to create/remove.
  - `AS400_NEW_USER_DESC` – User description.
  - `AS400_ACTION` – Either `create` or `remove`.

### For ACS (Primary)

- IBM Access Client Solutions installed.
- ACS `system` command available in PATH.

### For SSH (Backup Options)

- AS400 SSH service enabled.
- Admin account has SSH access.
- OpenSSH client installed.

---

## Scripts

### 1. PowerShell + ACS (as400_acs.ps1)

- Uses IBM ACS `system` command to run AS400 commands directly.

### 2. PowerShell + SSH (as400_ssh.ps1)

- Uses `ssh` from PowerShell to run AS400 commands.

### 3. Bash + SSH (as400_ssh.sh)

- Uses `ssh` from Bash shell to run AS400 commands.

---

## Example Commands

### Creating a user

  ```powershell
  $env:AS400_ACTION = "create"
  $env:AS400_HOST = "my-as400.example.com"
  $env:AS400_ADMIN_USER = "QSECOFR"
  $env:AS400_ADMIN_PASS = "supersecret"
  $env:AS400_NEW_USER = "TEMPUSER1"
  $env:AS400_NEW_USER_DESC = "Temporary user for troubleshooting"
  ./as400_acs.ps1
  ```

### Removing a user

  ```powershell
  $env:AS400_ACTION = "remove"
  ./as400_acs.ps1
  ```

---

## Primary & Backup Strategy

- **Primary:** Use ACS script (`as400_acs.ps1`) for direct command execution.
- **Backup #1:** Use SSH script (`as400_ssh.ps1`) if ACS is unavailable.
- **Backup #2:** Use Bash SSH script (`as400_ssh.sh`) for Linux/Mac environments.

---

## Installing IBM ACS

1. Download IBM ACS from IBM Fix Central.
2. Install Java if required.
3. Add `acslaunch_win-64.exe` and `system` command to your PATH.

## Installing SSH Client

- On Windows: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`
- On Mac/Linux: Already installed by default.
