
# AS400 Access Automation with Britive

**DRAFT SCRIPTS**

## Overview

This toolkit allows you to create and remove short-lived IBM i (AS400) accounts using Britive automation.
It supports three automation options:

### Primary & Backup Strategy

- **Primary:** Use ACS script (`as400_acs.ps1`) for direct command execution.
- **Backup #1:** Use SSH script (`as400_ssh.ps1`) if ACS is unavailable.
- **Backup #2:** Use Bash SSH script (`as400_ssh.sh`) for Linux/Mac environments.

Britive will handle time-based account expiry. These scripts simply create and remove users based on environment variables passed at runtime.

### Britive configured to pass required environment variables

- `AS400_HOST` – Hostname or IP of the AS400.
- `AS400_ADMIN_USER` – Admin username with authority to manage users.
- `AS400_ADMIN_PASS` – Admin password.
- `AS400_NEW_USER` – User ID to create/remove.
- `AS400_NEW_USER_DESC` – User description.
- `AS400_ACTION` – Either `checkout` or `checkin`. Automatically handled by Britive.

---

## Prerequisites

### On the IBM i (AS/400) System

1. **Automation Service Profile**:
   - Must have `*SECADM` authority (to create/change/delete user profiles).
   - `*ALLOBJ` authority recommended if broad access needs to be granted.
2. **SSH Access**:
   - SSH must be enabled (`STRTCPSVR SERVER(*SSHD)`).
   - The automation profile must be allowed to log in via SSH.
3. **CL Command Access**:
   - The automation profile must be able to run commands like:
     - `CRTUSRPRF`
     - `CHGUSRPRF`
     - `DLTUSRPRF`
     - `GRTOBJAUT`

### On the Access Broker Server

1. PowerShell 7+ installed ([Download PowerShell](https://github.com/PowerShell/PowerShell))
2. Network connectivity to the IBM i host.
3. SSH client installed (PowerShell 7+ includes one by default).

### For ACS (Primary)

- IBM Access Client Solutions installed.
- Download IBM ACS from IBM Fix Central.
- Add `acslaunch_win-64.exe` and `system` command to your PATH.

### For SSH (Backup Options)

- AS400 SSH service enabled.
- Admin account has SSH access.
- OpenSSH client installed.
  - On Windows: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`
  - On Mac/Linux: Already installed by default.

---

## Scripts

### 1. PowerShell + ACS (as400_acs.ps1)

- Uses IBM ACS `system` command to run AS400 commands directly.

### 2. PowerShell + SSH (as400_ssh.ps1)

- Uses `ssh` from PowerShell to run AS400 commands.

### 3. Bash + SSH (as400_ssh.sh)

- Uses `ssh` from Bash shell to run AS400 commands.
