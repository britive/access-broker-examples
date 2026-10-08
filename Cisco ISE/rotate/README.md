# Cisco ISE – Admin Password Rotation (break-glass)

Rotates the two kinds of standing administrator on an ISE node:

| Script | Account type | Mechanism |
|---|---|---|
| `rotate-ise-cli-admin.sh` | **CLI** (ADE-OS, SSH/console) administrator | `configure terminal` → `username <u> password plain <new> role <existing-role>` |
| `rotate-ise-gui-admin.sh` | **GUI** (admin portal) administrator, e.g. the built-in `admin` | `application reset-passwd ise <u>` from the CLI |

`ise-ssh-common.exp` is the shared login prologue; keep it next to the scripts.

Wire a script as **both** `checkout_script` and `checkin_script`: checkout sets a new secret and returns it to the user; checkin sets another and returns it to the broker for the Secrets Store. The value the user saw stops working at checkin.

Rotation never creates accounts. The CLI script reads the account's current `role` from `show running-config` and preserves it.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `ISE_HOST` | Yes | ISE node |
| `ISE_CLI_ADMIN_USER` / `ISE_CLI_ADMIN_PASSWORD` | Yes | CLI admin the broker logs in as (Secrets Store) |
| `ISE_TARGET_USER` | Yes | Account to rotate (`admin`); may equal `ISE_CLI_ADMIN_USER` for self-rotation |
| `ISE_NEW_PASSWORD` | No | Supply only when another system owns the value |
| `ISE_PASSWORD_LENGTH` | No | Default `20` |
| `ISE_KNOWN_HOSTS` / `ISE_ACCEPT_HOST_KEY` | No | Host-key policy |

## Output

```json
{"login":"admin","hostname":"ise-pan","password":"…","role":"admin"}
{"login":"admin","hostname":"ise-pan","password":"…","url":"https://ise-pan/admin/"}
```

## Britive Broker Config Example

```yaml
resource_types:
  cisco-ise-node:
    break-glass-gui-admin:
      max_supported_version: local
      execution_environment: /bin/sh -c "sudo -E <BRITIVE_PERMISSION_SCRIPT>"
      checkout_script: /opt/britive-broker/scripts/Cisco ISE/rotate/rotate-ise-gui-admin.sh
      checkin_script:  /opt/britive-broker/scripts/Cisco ISE/rotate/rotate-ise-gui-admin.sh
    break-glass-cli-admin:
      max_supported_version: local
      execution_environment: /bin/sh -c "sudo -E <BRITIVE_PERMISSION_SCRIPT>"
      checkout_script: /opt/britive-broker/scripts/Cisco ISE/rotate/rotate-ise-cli-admin.sh
      checkin_script:  /opt/britive-broker/scripts/Cisco ISE/rotate/rotate-ise-cli-admin.sh
```

## Notes

- In a deployment, GUI admin accounts are replicated from the PAN; run the GUI rotation against the Primary Admin Node only. CLI accounts are per node.
- `application reset-passwd` also clears an account lockout, which makes it the right tool when the break-glass admin has been locked by failed attempts.
- If the ISE password policy rejects the generated value, the script exits `1` with ISE's message; nothing was changed.
