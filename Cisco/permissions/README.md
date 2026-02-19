# Cisco IOS XE – Just-In-Time Privilege Escalation

These scripts implement **Just-In-Time (JIT) privileged access** for local user accounts on **Cisco Catalyst 9300** (IOS XE) switches via SSH, using the Britive Access Broker.

On IOS XE, each local user is assigned a privilege level between **1** (standard user EXEC) and **15** (full privileged EXEC). The checkout script creates an account at an elevated privilege level; the checkin script removes the account entirely — ensuring no standing privileged access exists between sessions.

Two language variants are provided — PowerShell and Bash — so you can choose the one that fits your broker host OS.

---

## Scripts

| Script | Language | Purpose |
|---|---|---|
| `checkout-cisco-privilege.ps1` | PowerShell | Create a local account with elevated privilege on checkout |
| `checkin-cisco-privilege.ps1` | PowerShell | Remove the local account on checkin |
| `checkout-cisco-privilege.sh` | Bash | Create a local account with elevated privilege on checkout |
| `checkin-cisco-privilege.sh` | Bash | Remove the local account on checkin |

---

## IOS XE Privilege Levels

| Level | Meaning |
|---|---|
| 1 | User EXEC — read-only `show` commands (default for new users) |
| 2–14 | Custom — intermediate access configurable via `privilege` commands |
| 15 | Privileged EXEC — equivalent to `enable` mode; full administrative access |

The checkout script defaults to **privilege 15**. Set `CISCO_ESCALATED_PRIVILEGE` to any value from 2–15 to grant a narrower scope of access.

---

## Prerequisites

### PowerShell scripts

| Requirement | Details |
|---|---|
| **PowerShell** | Windows PowerShell 5.1+ or PowerShell 7+ (cross-platform) |
| **Posh-SSH module** | `Install-Module Posh-SSH -Scope CurrentUser -Force` |
| **SSH access** | TCP 22 open from the broker host to each target switch |
| **Admin account** | SSH admin account must have privilege 15, or `CISCO_ENABLE_SECRET` must be set |
| **IOS XE version** | 16.x or later — required for `algorithm-type scrypt` (type-9 password hashing) |

### Bash scripts

| Requirement | Details |
|---|---|
| **Bash** | Version 4.0+ (standard on Linux; macOS ships 3.2 — install Bash 5 via Homebrew if needed) |
| **OpenSSH client** | `ssh` must be on `PATH`; pre-installed on most Linux distributions and macOS |
| **expect** | `apt install expect` / `yum install expect` / `brew install expect` |
| **SSH access** | TCP 22 open from the broker host to each target switch |
| **Admin account** | SSH admin account must have privilege 15, or `CISCO_ENABLE_SECRET` must be set |
| **IOS XE version** | 16.x or later — required for `algorithm-type scrypt` (type-9 password hashing) |

---

## checkout-cisco-privilege.ps1 / checkout-cisco-privilege.sh

Connects to a switch via SSH and creates (or updates) a local user account at the specified privilege level. If the account already exists, the `username` command overwrites the privilege level and password in place.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_SWITCH_HOST` | Yes | IP address or hostname of the target switch |
| `CISCO_ADMIN_USER` | Yes | Admin username used for the SSH connection |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password for the SSH connection |
| `CISCO_TARGET_USER` | Yes | Local username to create / escalate |
| `CISCO_TARGET_PASSWORD` | Yes | Password to set on the target account |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |
| `CISCO_ESCALATED_PRIVILEGE` | No | Privilege level to grant on checkout (default: `15`) |

### How It Works

1. Validates all required environment variables — fails immediately if any are missing.
2. Checks that the required SSH library is available (`Posh-SSH` for PowerShell; `expect` + `ssh` for Bash).
3. Opens an interactive SSH shell to the switch.
4. Reads the initial prompt:
   - If the prompt ends with `>` (user EXEC), sends `enable` and the enable secret to reach privileged EXEC (`#`).
   - If the prompt already ends with `#` (privilege 15), skips the enable step.
5. Enters global configuration mode with `configure terminal`.
6. Creates or escalates the account:
   ```
   username <CISCO_TARGET_USER> privilege <CISCO_ESCALATED_PRIVILEGE> algorithm-type scrypt secret <CISCO_TARGET_PASSWORD>
   ```
   The `algorithm-type scrypt` produces a type-9 hash — the strongest available on IOS XE.
7. Exits config mode with `end`.
8. Persists the configuration with `write memory`.
9. Closes the SSH session.
10. Exits `0` on success, `1` on any failure.

---

## checkin-cisco-privilege.ps1 / checkin-cisco-privilege.sh

Connects to a switch via SSH and removes the local user account entirely. This ensures no standing privileged access remains after the session ends.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_SWITCH_HOST` | Yes | IP address or hostname of the target switch |
| `CISCO_ADMIN_USER` | Yes | Admin username used for the SSH connection |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password for the SSH connection |
| `CISCO_TARGET_USER` | Yes | Local username to remove |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |

### How It Works

1. Validates all required environment variables — fails immediately if any are missing.
2. Checks that the required SSH library is available.
3. Opens an interactive SSH shell to the switch.
4. Elevates to privileged EXEC mode if needed (same enable logic as checkout).
5. Enters global configuration mode with `configure terminal`.
6. Removes the account:
   ```
   no username <CISCO_TARGET_USER>
   ```
7. Exits config mode with `end`.
8. Persists the configuration with `write memory`.
9. Closes the SSH session.
10. Exits `0` on success, `1` on any failure.

---

## Security Notes

- **Passwords are never written to stdout or logs.** Only usernames and switch hostnames appear in output.
- SSH host keys are auto-accepted on first connection (Posh-SSH `-AcceptKey -Force`; Bash `StrictHostKeyChecking=no`). For production deployments, pre-populate known hosts or manage host key verification explicitly.
- The target account password is passed to the switch inside the encrypted SSH session — never over plain text.
- `algorithm-type scrypt` (type-9) is used for password hashing. The switch stores only the hash, never the plain-text password.
- Because the account is fully removed on checkin, there is **no standing privileged account** between Britive sessions.

---

## Britive Broker Config Example

### PowerShell

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: jit-privilege-escalation
        checkout_script: Cisco/permissions/checkout-cisco-privilege.ps1
        checkin_script:  Cisco/permissions/checkin-cisco-privilege.ps1
        execution_environment: powershell
        environment_variables:
          - CISCO_SWITCH_HOST
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_TARGET_PASSWORD
          - CISCO_ENABLE_SECRET            # optional
          - CISCO_ESCALATED_PRIVILEGE      # optional — default 15
```

### Bash

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: jit-privilege-escalation
        checkout_script: Cisco/permissions/checkout-cisco-privilege.sh
        checkin_script:  Cisco/permissions/checkin-cisco-privilege.sh
        execution_environment: bash
        environment_variables:
          - CISCO_SWITCH_HOST
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_TARGET_PASSWORD
          - CISCO_ENABLE_SECRET            # optional
          - CISCO_ESCALATED_PRIVILEGE      # optional — default 15
```

---

## Privilege Level Quick Reference

To grant read-only network operator access instead of full admin, set `CISCO_ESCALATED_PRIVILEGE=7` (or another intermediate value matching your site's IOS privilege command customisation). The switch must have corresponding `privilege exec level <N>` commands configured to populate that level with specific commands.

For most JIT admin use cases, privilege **15** is appropriate and requires no additional switch configuration.
