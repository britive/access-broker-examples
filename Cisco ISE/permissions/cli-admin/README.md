# Cisco ISE – JIT CLI Administrator

Creates a temporary **ADE-OS CLI administrator** on an ISE node at checkout and removes it at checkin, over SSH. CLI admins are separate from GUI admins and are node-local; register each node as its own resource.

| Script | Purpose |
|---|---|
| `checkout.sh` | `username brt-<user> password plain <generated> role admin\|user`, verify, return credential |
| `checkin.sh` | `no username brt-<user>`, verify, retry once |

The username is the local part of `BRITIVE_USER_EMAIL` with `ISE_JIT_PREFIX` (default `brt-`). A leftover prefixed account is refreshed in place; with the prefix disabled, an existing account makes the checkout refuse.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `ISE_HOST` | Yes | ISE node |
| `ISE_CLI_ADMIN_USER` / `ISE_CLI_ADMIN_PASSWORD` | Yes | Existing CLI admin the broker uses (Secrets Store) |
| `BRITIVE_USER_EMAIL` | Yes | Requesting identity |
| `ISE_CLI_ROLE` | No | `admin` (default) or `user` |
| `ISE_JIT_PREFIX` | No | Default `brt-` |
| `ISE_PASSWORD_LENGTH` | No | Default `20` (always contains upper, lower and digit to satisfy ISE policy) |
| `ISE_CHECKIN_RETRIES` | No | checkin only; default `1` |
| `ISE_KNOWN_HOSTS` / `ISE_ACCEPT_HOST_KEY` | No | Host-key policy; verification is on by default |

## Output

```json
{"login":"brt-alice","hostname":"ise-psn-01","password":"…","ssh_command":"ssh brt-alice@ise-psn-01"}
```

## Britive Broker Config Example

```yaml
resource_types:
  cisco-ise-node:
    jit-cli-admin:
      max_supported_version: local
      execution_environment: /bin/sh -c "sudo -E <BRITIVE_PERMISSION_SCRIPT>"
      checkout_script: /opt/britive-broker/scripts/Cisco ISE/permissions/cli-admin/checkout.sh
      checkin_script:  /opt/britive-broker/scripts/Cisco ISE/permissions/cli-admin/checkin.sh
```

## Notes

- ISE's CLI password policy applies to the generated password; the default length and character mix satisfy the shipped policy. If you have tightened it (special characters required), set `ISE_PASSWORD_LENGTH` and adjust the generator.
- The broker's CLI admin must have `role admin`; `role user` cannot manage accounts.
- To broker the SSH session itself (recording, no credential shown), front the node with Britive Bridge.
