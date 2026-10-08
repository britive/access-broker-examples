# Cisco IOS XE – Just-In-Time Privilege Escalation

These scripts implement **Just-In-Time (JIT) privileged access** for local user accounts on Cisco **IOS / IOS XE** devices (Catalyst, ISR, ASR, Catalyst 8000) via SSH, using the Britive Access Broker. They were developed and tested on Catalyst 9300; the commands they issue are standard IOS XE.

On IOS XE, each local user is assigned a privilege level between **1** (standard user EXEC) and **15** (full privileged EXEC). The checkout script creates an account at an elevated privilege level; the checkin script removes the account entirely — ensuring no standing privileged access exists between sessions.

Two language variants are provided — PowerShell and Bash — so you can choose the one that fits your broker host OS. Both emit the same result contract.

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

## Account naming

The local username is derived from the Britive identity (`alice@example.com` → `alice`) and then prefixed with `CISCO_JIT_PREFIX` (default `brt-`), giving `brt-alice`. The prefix guarantees a JIT account can never collide with — or be deleted in place of — a standing local account such as `admin` or `netops`.

- If `brt-alice` already exists at checkout, it is a leftover from a failed checkin and is refreshed in place (new password, requested privilege).
- If you set `CISCO_JIT_PREFIX=""`, checkout **refuses** to proceed when an account with that name already exists.

---

## Prerequisites

### PowerShell scripts

| Requirement | Details |
|---|---|
| **PowerShell** | Windows PowerShell 5.1+ or PowerShell 7+ (cross-platform) |
| **Posh-SSH module** | `Install-Module Posh-SSH -Scope CurrentUser -Force` |
| **SSH access** | TCP 22 open from the broker host to each target switch |
| **Host key** | Trust each switch first: `New-SSHTrustedHost -HostName <switch> -FingerPrint <sha256>` (or set `CISCO_ACCEPT_HOST_KEY=true` in a lab) |
| **Admin account** | SSH admin account must have privilege 15, or `CISCO_ENABLE_SECRET` must be set |
| **IOS XE version** | 16.x or later — required for `algorithm-type scrypt` (type-9 password hashing) |

### Bash scripts

| Requirement | Details |
|---|---|
| **Bash** | Version 4.0+ (standard on Linux; macOS ships 3.2 — install Bash 5 via Homebrew if needed) |
| **OpenSSH client** | `ssh` must be on `PATH`; pre-installed on most Linux distributions and macOS |
| **expect** | `apt install expect` / `yum install expect` / `brew install expect` |
| **SSH access** | TCP 22 open from the broker host to each target switch |
| **Host key** | Each switch's host key in `~/.ssh/known_hosts` of the broker user, or a file passed via `CISCO_KNOWN_HOSTS` (or set `CISCO_ACCEPT_HOST_KEY=true` in a lab) |
| **Admin account** | SSH admin account must have privilege 15, or `CISCO_ENABLE_SECRET` must be set |
| **IOS XE version** | 16.x or later — required for `algorithm-type scrypt` (type-9 password hashing) |

---

## checkout-cisco-privilege.ps1 / checkout-cisco-privilege.sh

Connects to a switch via SSH and creates (or refreshes) a prefixed local user account at the specified privilege level, verifies it is present, and saves the configuration.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_SWITCH_HOST` | Yes | IP address or hostname of the target switch |
| `CISCO_ADMIN_USER` | Yes | Admin username used for the SSH connection |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password for the SSH connection |
| `CISCO_TARGET_USER` | Yes | Britive identity as an email address (`alice@example.com`); the domain is stripped and `CISCO_JIT_PREFIX` applied |
| `CISCO_TARGET_PASSWORD` | No | Password to set on the target account. If unset, a strong random password is generated |
| `CISCO_PASSWORD_LENGTH` | No | Length of the generated password (default: `20`) |
| `CISCO_ESCALATED_PRIVILEGE` | No | Privilege level to grant on checkout (default: `15`) |
| `CISCO_JIT_PREFIX` | No | Prefix for the derived username (default: `brt-`; `""` disables, see [Account naming](#account-naming)) |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |
| `CISCO_KNOWN_HOSTS` | No | Bash only. Path to a known_hosts file holding the switch host key (default: `~/.ssh/known_hosts`) |
| `CISCO_ACCEPT_HOST_KEY` | No | `true` to accept unknown host keys on first connect (default: `false`; lab use only) |

### How It Works

1. Validates all required environment variables — fails immediately if any are missing.
2. Derives the local username (`alice@example.com` → `brt-alice`) and generates a password if none was supplied.
3. Checks that the required SSH library is available (`Posh-SSH` for PowerShell; `expect` + `ssh` for Bash).
4. Opens an interactive SSH shell to the switch, verifying the host key.
5. Reads the initial prompt (anchored to the end of the output, so a `#` or `>` inside a login banner is ignored):
   - If the prompt ends with `>` (user EXEC), sends `enable` and the enable secret to reach privileged EXEC (`#`).
   - If the prompt already ends with `#` (privilege 15), skips the enable step.
6. Pre-flight: `show running-config | include ^username <user> ` — refreshes a leftover prefixed account, or refuses to touch an unprefixed one that already exists.
7. Enters global configuration mode with `configure terminal`.
8. Creates or escalates the account:
   ```
   username <user> privilege <CISCO_ESCALATED_PRIVILEGE> algorithm-type scrypt secret <password>
   ```
   The `algorithm-type scrypt` produces a type-9 hash — the strongest available on IOS XE.
9. Exits config mode with `end` and verifies the account is now in the running configuration. If it is not, the script exits `1` without saving.
10. Persists the configuration with `write memory`.
11. Closes the SSH session and prints the result (below) on stdout.
12. Exits `0` on success, `1` on any failure.

### Output

All progress and errors go to **stderr** (PowerShell: the host/warning/error streams). **stdout carries exactly one line**, the credential the broker returns to the user:

```json
{"login":"brt-alice","hostname":"10.0.1.1","password":"…","connection_string":"ssh://brt-alice:…@10.0.1.1:22","ssh_command":"ssh -o PubkeyAcceptedKeyTypes=+ssh-rsa brt-alice@10.0.1.1"}
```

Do not capture stdout into a log.

---

## checkin-cisco-privilege.ps1 / checkin-cisco-privilege.sh

Connects to a switch via SSH, removes the prefixed local user account, verifies it is gone, and saves the configuration. The operation is idempotent: running it against an account that no longer exists still succeeds.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_SWITCH_HOST` | Yes | IP address or hostname of the target switch |
| `CISCO_ADMIN_USER` | Yes | Admin username used for the SSH connection |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password for the SSH connection |
| `CISCO_TARGET_USER` | Yes | Same Britive identity used at checkout |
| `CISCO_JIT_PREFIX` | No | Must match the value used at checkout (default: `brt-`) |
| `CISCO_CHECKIN_RETRIES` | No | Extra attempts if removal fails (default: `1`) |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |
| `CISCO_KNOWN_HOSTS` | No | Bash only. Path to a known_hosts file (default: `~/.ssh/known_hosts`) |
| `CISCO_ACCEPT_HOST_KEY` | No | `true` to accept unknown host keys (default: `false`; lab use only) |

### How It Works

1. Validates all required environment variables — fails immediately if any are missing.
2. Checks that the required SSH library is available.
3. Opens an interactive SSH shell to the switch, verifying the host key.
4. Elevates to privileged EXEC mode if needed (same enable logic as checkout).
5. Enters global configuration mode with `configure terminal`.
6. Removes the account, accepting the IOS XE 17.x `[confirm]` prompt if it appears:
   ```
   no username <user>
   ```
7. Exits config mode with `end` and verifies the account is no longer in the running configuration. If it still is, the script exits `1` without saving.
8. Persists the configuration with `write memory`.
9. On failure, retries the whole sequence up to `CISCO_CHECKIN_RETRIES` more times (5 s apart) before exiting `1` with a manual-remediation hint. A failed checkin is the one failure mode that leaves standing privilege behind, so treat a non-zero exit as an alert, not a log line.

Checkin prints nothing on stdout.

---

## Security Notes

- **stdout is the credential channel.** The checkout password appears on stdout exactly once, as JSON, for the broker to return to the user. It never appears on stderr, in progress messages, or in the PowerShell host stream. Do not redirect stdout into a log.
- **Host keys are verified by default.** Bash uses OpenSSH's `known_hosts` (`CISCO_KNOWN_HOSTS` overrides the file); PowerShell uses Posh-SSH's trusted-host store. `CISCO_ACCEPT_HOST_KEY=true` restores trust-on-first-use for lab environments.
- The target account password is passed to the switch inside the encrypted SSH session — never over plain text.
- `algorithm-type scrypt` (type-9) is used for password hashing. The switch stores only the hash, never the plain-text password.
- JIT accounts are prefixed, so the scripts can never overwrite or delete a standing local account.
- Because the account is fully removed on checkin, there is **no standing privileged account** between Britive sessions.

---

## Britive Broker Config Example

The broker config is a map of resource type → permission → script settings (see [`broker-config.yml.template`](../../broker-config.yml.template) at the repository root). The variables above are supplied to the script as environment variables from the Resource Manager resource parameters (`CISCO_SWITCH_HOST`) and profile permission variables (`CISCO_ESCALATED_PRIVILEGE`, …); name them exactly as the scripts expect. Store `CISCO_ADMIN_PASSWORD` and `CISCO_ENABLE_SECRET` in the Britive Secrets Store, never in this file.

### Bash

```yaml
resource_types:
  cisco-ios-xe:
    jit-privilege:
      max_supported_version: local
      execution_environment: /bin/sh -c "sudo -E <BRITIVE_PERMISSION_SCRIPT>"
      checkout_script: /opt/britive-broker/scripts/Cisco/permissions/checkout-cisco-privilege.sh
      checkin_script:  /opt/britive-broker/scripts/Cisco/permissions/checkin-cisco-privilege.sh
```

### PowerShell

```yaml
resource_types:
  cisco-ios-xe:
    jit-privilege:
      max_supported_version: local
      execution_environment: pwsh -NonInteractive -File <BRITIVE_PERMISSION_SCRIPT>
      checkout_script: C:\britive-broker\scripts\Cisco\permissions\checkout-cisco-privilege.ps1
      checkin_script:  C:\britive-broker\scripts\Cisco\permissions\checkin-cisco-privilege.ps1
```

A profile permission that grants read-only access instead of full admin sets `CISCO_ESCALATED_PRIVILEGE` as a permission variable:

```hcl
resource "britive_resource_manager_profile_permission" "cisco_readonly" {
  profile_id = britive_resource_manager_profile.cisco_readonly.id
  name       = "jit-privilege"
  version    = "latest"

  variables {
    name              = "CISCO_ESCALATED_PRIVILEGE"
    value             = "1"
    is_system_defined = false
  }
}
```

---

## Privilege Level Quick Reference

To grant read-only network operator access instead of full admin, set `CISCO_ESCALATED_PRIVILEGE=7` (or another intermediate value matching your site's IOS privilege command customization). The switch must have corresponding `privilege exec level <N>` commands configured to populate that level with specific commands.

For most JIT admin use cases, privilege **15** is appropriate and requires no additional switch configuration.

If the devices authenticate administrators through Cisco ISE (TACACS+), consider elevating at the AAA layer instead — one Britive profile can then cover the whole estate without per-device scripts. See the Cisco IOS XE section on [learn.britive.com](https://learn.britive.com/integrations/infrastructure/cisco/) for that pattern.
