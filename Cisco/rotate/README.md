# Cisco IOS XE – Local Account Password Rotation

These scripts rotate local user account passwords on Cisco **IOS / IOS XE** devices (Catalyst, ISR, ASR, Catalyst 8000) via SSH, using the Britive Access Broker to automate credential lifecycle management. They were developed and tested on Catalyst 9300; the commands they issue are standard IOS XE.

They are intended for **break-glass and service accounts that must always exist** on the device (`admin`, `netops`, a monitoring user). For per-user JIT access, use [`../permissions/`](../permissions/README.md) instead.

Two language variants are provided — PowerShell and Bash — so you can choose the one that fits your broker host OS. Both emit the same result contract.

---

## Scripts

| Script | Language | Purpose |
|---|---|---|
| `rotate-cisco-secret.ps1` | PowerShell | Rotate a local user's secret on a **single** switch, preserving their privilege level |
| `rotate-cisco-secret.sh` | Bash | Rotate a local user's secret on a **single** switch, preserving their privilege level |
| `rotate-cisco-account.ps1` | PowerShell | Rotate a local user's password **and** set their privilege level on a **single** switch |
| `rotate-cisco-account.sh` | Bash | Rotate a local user's password **and** set their privilege level on a **single** switch |
| `rotate-cisco-account-multi.ps1` | PowerShell | Rotate a local user's password and privilege level across a **group** of switches |
| `rotate-cisco-account-multi.sh` | Bash | Rotate a local user's password and privilege level across a **group** of switches |

---

## How rotation fits a Britive checkout

A rotation permission is wired with the same script as both `checkout_script` and `checkin_script`, which gives the break-glass pattern:

| Event | What runs | Effect |
|---|---|---|
| **Checkout** | rotate script | A new secret is set on the device and returned to the user (stdout JSON). The user has the only copy for the life of the session. |
| **Checkin / expiry** | rotate script | A new secret is set again and returned to the broker, which stores it. The value the user saw no longer works. |

Supply `CISCO_NEW_PASSWORD` only if an external system owns the value (for example, Secret Synchronization pushing a known secret). Otherwise leave it unset and let the script generate one.

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

## Common environment variables

| Variable | Required | Description |
|---|---|---|
| `CISCO_ADMIN_USER` | Yes | Admin username used for the SSH connection |
| `CISCO_ADMIN_PASSWORD` | Yes | Admin password for the SSH connection |
| `CISCO_TARGET_USER` | Yes | Local username whose secret will be rotated (used as-is; no prefix, no domain stripping) |
| `CISCO_NEW_PASSWORD` | No | The new secret to set. If unset, a strong random value is generated and returned on stdout |
| `CISCO_PASSWORD_LENGTH` | No | Length of the generated value (default: `20`) |
| `CISCO_ENABLE_SECRET` | No | Enable mode secret — only needed if the admin account is not privilege 15 |
| `CISCO_KNOWN_HOSTS` | No | Bash only. Path to a known_hosts file holding the switch host key (default: `~/.ssh/known_hosts`) |
| `CISCO_ACCEPT_HOST_KEY` | No | `true` to accept unknown host keys on first connect (default: `false`; lab use only) |

Per-script additions:

| Variable | Scripts | Description |
|---|---|---|
| `CISCO_SWITCH_HOST` | `rotate-cisco-secret.*`, `rotate-cisco-account.*` | IP address or hostname of the target switch |
| `CISCO_SWITCH_HOSTS` | `rotate-cisco-account-multi.*` | Comma-separated list of switch IPs/hostnames (e.g. `10.0.1.1,10.0.1.2,sw-core-01`) |
| `CISCO_PRIVILEGE_LEVEL` | `rotate-cisco-account*.*` | Privilege level to assign to the target user (default: `15`). Not used by `rotate-cisco-secret.*`, which never touches privilege |

---

## rotate-cisco-secret.ps1 / rotate-cisco-secret.sh — Single Switch, Secret Only

Rotates the stored secret (password hash) for a local user **without touching the account's privilege level**. Use this when you only need to refresh the credential and want to guarantee the privilege assignment is never altered.

```
username <CISCO_TARGET_USER> algorithm-type scrypt secret <new-secret>
```

Omitting the `privilege` keyword causes IOS XE to update only the stored secret hash.

## rotate-cisco-account.ps1 / rotate-cisco-account.sh — Single Switch

Rotates the password **and** sets the privilege level:

```
username <CISCO_TARGET_USER> privilege <CISCO_PRIVILEGE_LEVEL> algorithm-type scrypt secret <new-secret>
```

## rotate-cisco-account-multi.ps1 / rotate-cisco-account-multi.sh — Multiple Switches

Rotates the same user to the **same new secret** across every switch in `CISCO_SWITCH_HOSTS`, sequentially. A per-switch failure is recorded and the remaining switches are still processed. The script exits `1` if **any** switch failed, `0` only if **all** succeeded — but the JSON result (below) is emitted either way, so the broker can store the new secret for the switches that did rotate.

---

## How It Works (all scripts)

1. Validates required environment variables — fails immediately if any are missing.
2. Generates the new secret if `CISCO_NEW_PASSWORD` is unset (alphanumeric, crypto RNG).
3. Checks that the required SSH library is available (`Posh-SSH` for PowerShell; `expect` + `ssh` for Bash).
4. Opens an interactive SSH shell to the switch, verifying the host key.
5. Reads the initial prompt (anchored to the end of the output, so a `#` or `>` inside a login banner is ignored) and elevates with `enable` if it ends in `>`.
6. Enters global configuration mode, issues the `username` command, exits with `end`.
7. Persists the configuration with `write memory`.
8. Closes the SSH session and prints the result on stdout.
9. Exits `0` on success, `1` on any failure.

## Output

All progress and errors go to **stderr** (PowerShell: the host/warning/error streams). **stdout carries exactly one line** of JSON, the new secret, for the broker to store or return:

Single switch:

```json
{"login":"netops","hostname":"10.0.1.1","password":"…"}
```

Multiple switches:

```json
{"login":"netops","password":"…","rotated":2,"failed":1,"results":[{"hostname":"10.0.1.1","status":"OK"},{"hostname":"10.0.1.2","status":"OK"},{"hostname":"10.0.1.3","status":"FAIL"}]}
```

The human-readable summary table (`[OK]` / `[FAIL]` per switch) is still printed, on stderr.

---

## Security Notes

- **stdout is the credential channel.** The new secret appears on stdout exactly once, as JSON. It never appears in progress messages. Do not redirect stdout into a log.
- **Host keys are verified by default.** Bash uses OpenSSH's `known_hosts` (`CISCO_KNOWN_HOSTS` overrides the file); PowerShell uses Posh-SSH's trusted-host store. `CISCO_ACCEPT_HOST_KEY=true` restores trust-on-first-use for lab environments.
- The new password is passed to the switch inside the encrypted SSH session — never over plain text.
- `algorithm-type scrypt` (type-9) is used for password hashing. The switch stores only the hash.
- A failed multi-switch run leaves the fleet with **two** valid secrets for the account (old on the failed switches, new on the rest). Re-run against the failed hosts with `CISCO_NEW_PASSWORD` set to the value from the JSON result to converge.

---

## Britive Broker Config Example

The broker config is a map of resource type → permission → script settings (see [`broker-config.yml.template`](../../broker-config.yml.template) at the repository root). The variables above are supplied to the script as environment variables from the Resource Manager resource parameters (`CISCO_SWITCH_HOST` / `CISCO_SWITCH_HOSTS`) and profile permission variables (`CISCO_TARGET_USER`, `CISCO_PRIVILEGE_LEVEL`); name them exactly as the scripts expect. Store `CISCO_ADMIN_PASSWORD` and `CISCO_ENABLE_SECRET` in the Britive Secrets Store, never in this file.

### Bash — single switch

```yaml
resource_types:
  cisco-ios-xe:
    rotate-local-secret:
      max_supported_version: local
      execution_environment: /bin/sh -c "sudo -E <BRITIVE_PERMISSION_SCRIPT>"
      checkout_script: /opt/britive-broker/scripts/Cisco/rotate/rotate-cisco-secret.sh
      checkin_script:  /opt/britive-broker/scripts/Cisco/rotate/rotate-cisco-secret.sh
```

### Bash — multiple switches

```yaml
resource_types:
  cisco-ios-xe-fleet:
    rotate-local-account:
      max_supported_version: local
      execution_environment: /bin/sh -c "sudo -E <BRITIVE_PERMISSION_SCRIPT>"
      checkout_script: /opt/britive-broker/scripts/Cisco/rotate/rotate-cisco-account-multi.sh
      checkin_script:  /opt/britive-broker/scripts/Cisco/rotate/rotate-cisco-account-multi.sh
```

### PowerShell — single switch

```yaml
resource_types:
  cisco-ios-xe:
    rotate-local-secret:
      max_supported_version: local
      execution_environment: pwsh -NonInteractive -File <BRITIVE_PERMISSION_SCRIPT>
      checkout_script: C:\britive-broker\scripts\Cisco\rotate\rotate-cisco-secret.ps1
      checkin_script:  C:\britive-broker\scripts\Cisco\rotate\rotate-cisco-secret.ps1
```

Swap the script name for `rotate-cisco-account.ps1` or `rotate-cisco-account-multi.ps1` as needed; the multi variant reads `CISCO_SWITCH_HOSTS` (plural) instead of `CISCO_SWITCH_HOST`.
