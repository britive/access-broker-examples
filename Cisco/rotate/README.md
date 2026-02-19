# Cisco IOS XE – Local Account Password Rotation

These scripts rotate local user account passwords on **Cisco Catalyst 9300** (IOS XE) switches via SSH, using the Britive Access Broker to automate credential lifecycle management.

Two language variants are provided — PowerShell and Bash — so you can choose the one that fits your broker host OS.

---

## Scripts

| Script | Language | Purpose |
|---|---|---|
| `rotate-cisco-secret.ps1` | PowerShell | Rotate a local user's secret on a **single** switch, preserving their privilege level |
| `rotate-cisco-secret.sh` | Bash | Rotate a local user's secret on a **single** switch, preserving their privilege level |
| `rotate-cisco-account.ps1` | PowerShell | Rotate a local user's password **and** set their privilege level on a **single** switch |
| `rotate-cisco-account-multi.ps1` | PowerShell | Rotate a local user's password and privilege level across a **group** of switches |
| `rotate-cisco-account.sh` | Bash | Rotate a local user's password **and** set their privilege level on a **single** switch |
| `rotate-cisco-account-multi.sh` | Bash | Rotate a local user's password and privilege level across a **group** of switches |

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

## rotate-cisco-secret.ps1 / rotate-cisco-secret.sh — Single Switch, Secret Only

Connects to one switch via SSH and rotates the stored secret (password hash) for a specified local user **without touching the account's privilege level**. Use this when you only need to refresh the credential and want to guarantee the account's privilege assignment is never altered.

The IOS XE command issued is:

```
username <CISCO_TARGET_USER> algorithm-type scrypt secret <CISCO_NEW_PASSWORD>
```

Omitting the `privilege` keyword causes IOS XE to update only the stored secret hash; the account's existing privilege level is preserved.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_SWITCH_HOST` | Yes | IP address or hostname of the target switch |
| `CISCO_ADMIN_USER` | Yes | Admin username used for the SSH connection |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password for the SSH connection |
| `CISCO_TARGET_USER` | Yes | Local username whose secret will be rotated |
| `CISCO_NEW_PASSWORD` | Yes | The new secret to set |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |

### How It Works

1. Validates all required environment variables — fails immediately if any are missing.
2. Checks that the required SSH library is available (`Posh-SSH` for PowerShell; `expect` + `ssh` for Bash).
3. Opens an interactive SSH shell to the switch.
4. Reads the initial prompt:
   - If the prompt ends with `>` (user EXEC), sends `enable` and the enable secret to reach privileged EXEC (`#`).
   - If the prompt already ends with `#` (privilege 15), skips the enable step.
5. Enters global configuration mode with `configure terminal`.
6. Updates only the stored secret:
   ```
   username <CISCO_TARGET_USER> algorithm-type scrypt secret <CISCO_NEW_PASSWORD>
   ```
   The `algorithm-type scrypt` produces a type-9 hash — the strongest available on IOS XE.
7. Exits config mode with `end`.
8. Persists the configuration with `write memory`.
9. Closes the SSH session.
10. Exits `0` on success, `1` on any failure.

### Britive Broker Config Example — PowerShell

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: rotate-local-secret
        checkout_script: Cisco/rotate/rotate-cisco-secret.ps1
        checkin_script:  Cisco/rotate/rotate-cisco-secret.ps1
        execution_environment: powershell
        environment_variables:
          - CISCO_SWITCH_HOST
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_NEW_PASSWORD
          - CISCO_ENABLE_SECRET      # optional
```

### Britive Broker Config Example — Bash

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: rotate-local-secret
        checkout_script: Cisco/rotate/rotate-cisco-secret.sh
        checkin_script:  Cisco/rotate/rotate-cisco-secret.sh
        execution_environment: bash
        environment_variables:
          - CISCO_SWITCH_HOST
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_NEW_PASSWORD
          - CISCO_ENABLE_SECRET      # optional
```

---

## rotate-cisco-account.ps1 / rotate-cisco-account.sh — Single Switch

Connects to one switch via SSH and rotates the password for a specified local user, also setting their privilege level.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_SWITCH_HOST` | Yes | IP address or hostname of the target switch |
| `CISCO_ADMIN_USER` | Yes | Admin username used for the SSH connection |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password for the SSH connection |
| `CISCO_TARGET_USER` | Yes | Local username whose password will be rotated |
| `CISCO_NEW_PASSWORD` | Yes | The new password to set |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |
| `CISCO_PRIVILEGE_LEVEL` | No | Privilege level to assign to the target user (default: `15`) |

### How It Works

1. Validates all required environment variables — fails immediately if any are missing.
2. Checks that the required SSH library is available (`Posh-SSH` for PowerShell; `expect` + `ssh` for Bash).
3. Opens an interactive SSH shell to the switch.
4. Reads the initial prompt:
   - If the prompt ends with `>` (user EXEC), sends `enable` and the enable secret to reach privileged EXEC (`#`).
   - If the prompt already ends with `#` (privilege 15), skips the enable step.
5. Enters global configuration mode with `configure terminal`.
6. Sets the new password:
   ```
   username <CISCO_TARGET_USER> privilege <CISCO_PRIVILEGE_LEVEL> algorithm-type scrypt secret <CISCO_NEW_PASSWORD>
   ```
   The `algorithm-type scrypt` produces a type-9 hash — the strongest available on IOS XE.
7. Exits config mode with `end`.
8. Persists the configuration with `write memory`.
9. Closes the SSH session.
10. Exits `0` on success, `1` on any failure.

---

## rotate-cisco-account-multi.ps1 / rotate-cisco-account-multi.sh — Multiple Switches

Rotates the same user's password across a comma-separated list of switches. Each switch is processed sequentially. Results are reported per-switch in a summary table at the end.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_SWITCH_HOSTS` | Yes | Comma-separated list of switch IPs/hostnames (e.g. `10.0.1.1,10.0.1.2,sw-core-01`) |
| `CISCO_ADMIN_USER` | Yes | Admin username (shared across all switches) |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password (shared across all switches) |
| `CISCO_TARGET_USER` | Yes | Local username whose password will be rotated |
| `CISCO_NEW_PASSWORD` | Yes | The new password to set |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |
| `CISCO_PRIVILEGE_LEVEL` | No | Privilege level to assign to the target user (default: `15`) |

### How It Works

1. Validates all required environment variables — fails immediately if any are missing.
2. Parses `CISCO_SWITCH_HOSTS` into a list (trims whitespace, ignores empty entries).
3. Checks that the required SSH library is available.
4. For each switch, performs the same rotation steps as the single-switch script.
   - A per-switch failure is caught and recorded without stopping the remaining switches.
5. Prints a summary table showing `[OK]` or `[FAIL]` for each switch.
6. Exits `1` if **any** switch failed, `0` only if **all** switches succeeded.

### Example Summary Output

```
═══════════════════════════════════════════════════════════════
Rotation Summary – user 'netops'
═══════════════════════════════════════════════════════════════
  [OK]    10.0.1.1
  [OK]    10.0.1.2
  [FAIL]  10.0.1.3
═══════════════════════════════════════════════════════════════
```

---

## Security Notes

- **Passwords are never written to stdout or logs.** Only usernames and switch hostnames appear in output.
- SSH host keys are auto-accepted on first connection (Posh-SSH `-AcceptKey -Force`; Bash `StrictHostKeyChecking=no`). For production deployments, pre-populate known hosts or manage host key verification explicitly.
- The new password is passed to the switch inside the encrypted SSH session — never over plain text.
- `algorithm-type scrypt` (type-9) is used for password hashing. This is the most secure option available on IOS XE; the switch stores only the hash.

---

## Britive Broker Config Example

### Single Switch — PowerShell

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: rotate-local-account
        checkout_script: Cisco/rotate/rotate-cisco-account.ps1
        checkin_script:  Cisco/rotate/rotate-cisco-account.ps1
        execution_environment: powershell
        environment_variables:
          - CISCO_SWITCH_HOST
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_NEW_PASSWORD
          - CISCO_ENABLE_SECRET      # optional
          - CISCO_PRIVILEGE_LEVEL    # optional
```

### Single Switch — Bash

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: rotate-local-account
        checkout_script: Cisco/rotate/rotate-cisco-account.sh
        checkin_script:  Cisco/rotate/rotate-cisco-account.sh
        execution_environment: bash
        environment_variables:
          - CISCO_SWITCH_HOST
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_NEW_PASSWORD
          - CISCO_ENABLE_SECRET      # optional
          - CISCO_PRIVILEGE_LEVEL    # optional
```

### Multiple Switches — PowerShell

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: rotate-local-account
        checkout_script: Cisco/rotate/rotate-cisco-account-multi.ps1
        checkin_script:  Cisco/rotate/rotate-cisco-account-multi.ps1
        execution_environment: powershell
        environment_variables:
          - CISCO_SWITCH_HOSTS        # comma-separated, e.g. "10.0.1.1,10.0.1.2,sw-core-01"
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_NEW_PASSWORD
          - CISCO_ENABLE_SECRET      # optional
          - CISCO_PRIVILEGE_LEVEL    # optional
```

### Multiple Switches — Bash

```yaml
resource_types:
  - name: cisco-switch
    permissions:
      - name: rotate-local-account
        checkout_script: Cisco/rotate/rotate-cisco-account-multi.sh
        checkin_script:  Cisco/rotate/rotate-cisco-account-multi.sh
        execution_environment: bash
        environment_variables:
          - CISCO_SWITCH_HOSTS        # comma-separated, e.g. "10.0.1.1,10.0.1.2,sw-core-01"
          - CISCO_ADMIN_USER
          - CISCO_ADMIN_PASSWORD
          - CISCO_TARGET_USER
          - CISCO_NEW_PASSWORD
          - CISCO_ENABLE_SECRET      # optional
          - CISCO_PRIVILEGE_LEVEL    # optional
```

> **Note:** The key difference from single-switch configs is the variable name: `CISCO_SWITCH_HOSTS` (plural, comma-separated list) instead of `CISCO_SWITCH_HOST` (singular).
