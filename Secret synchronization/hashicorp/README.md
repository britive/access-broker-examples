# HashiCorp Vault — Secret Synchronization

Writes a secret value from the Britive broker into a **HashiCorp Vault** KV secret. Britive manages the credential lifecycle (rotation policy, versioning, access governance); these scripts ensure the downstream KV entry always reflects the latest value.

Supports both **KV secrets engine v1** and **v2**, token authentication, and AppRole authentication. Also supports **HCP Vault Dedicated** and **Vault Enterprise** namespaces.

---

## Scripts

| Script | Tooling required | Best for |
| --- | --- | --- |
| `sync-to-hashicorp-vault.sh` | Vault CLI | Broker hosts with the Vault CLI installed |
| `sync-to-hashicorp-vault-curl.sh` | `curl`, `jq` | Minimal container images; no CLI available |
| `sync-to-hashicorp-vault.ps1` | PowerShell 5.1+ | Windows broker hosts |

---

## How It Works

1. The Britive platform calls the script at checkout time and injects all required values as environment variables.
2. The script authenticates to Vault using either a token or the AppRole auth method.
3. The script writes `SECRET_VALUE` to the specified KV path under the specified key name.
   - **KV v2**: Uses `vault kv put` / `POST /v1/<mount>/data/<path>`. Each write creates a new version; Vault keeps the full version history.
   - **KV v1**: Uses `vault write` / `POST /v1/<path>`. Overwrites the previous value with no version history.

---

## Prerequisites

### All scripts
- Network access to the Vault server address (`VAULT_ADDR`) on port 443 (or 8200 for non-TLS dev environments)
- The authenticating token or AppRole role must have a policy granting write access to `VAULT_SECRET_PATH`

### CLI variant (`sync-to-hashicorp-vault.sh`)
- **Vault CLI** installed and on `PATH`

### curl and PowerShell variants
- `curl`, `jq` (bash) or `Invoke-RestMethod` (PowerShell, built-in)

---

## Environment Variables

### Required (injected by the Britive broker)

| Variable | Description |
| --- | --- |
| `SECRET_VALUE` | The secret value to write — provided by the Britive platform |
| `VAULT_ADDR` | Vault server URL, e.g. `https://vault.example.com:8200` |
| `VAULT_TOKEN` | Vault token with write access (or use AppRole below) |
| `VAULT_SECRET_PATH` | KV mount + path, e.g. `secret/my-app/database` |
| `VAULT_SECRET_KEY` | Key name within the KV secret, e.g. `password` |

### AppRole authentication (alternative to `VAULT_TOKEN`)

| Variable | Description |
| --- | --- |
| `VAULT_ROLE_ID` | AppRole role ID |
| `VAULT_SECRET_ID_AR` | AppRole secret ID — note the `_AR` suffix distinguishes it from `SECRET_VALUE` |

### Optional

| Variable | Default | Description |
| --- | --- | --- |
| `VAULT_KV_VERSION` | `2` | KV engine version: `1` or `2` |
| `VAULT_MOUNT_PATH` | `secret` | KV mount path (used for `data/` path rewriting in KV v2) |
| `VAULT_NAMESPACE` | — | Vault namespace for HCP Vault Dedicated or Enterprise |
| `VAULT_SKIP_VERIFY` | `false` | Set to `true` to skip TLS certificate verification |

---

## Vault Policy

Grant only the permissions needed to write the specific secret path:

```hcl
# Allow writing to the specific path only
path "secret/data/my-app/database" {
  capabilities = ["create", "update"]
}

# KV v1
path "secret/my-app/database" {
  capabilities = ["create", "update"]
}
```

- Do not grant `read` or `list` unless required.
- Scope the policy path to the exact secret, not a wildcard prefix (`secret/data/*`).
- Attach the policy to a dedicated token or AppRole — do not reuse an application token.

---

## KV v1 vs KV v2

| Feature | KV v1 | KV v2 |
| --- | --- | --- |
| Version history | None — each write overwrites | Full history; each write is a new version |
| Path format | `<mount>/<path>` | `<mount>/data/<path>` |
| CLI command | `vault write` | `vault kv put` |
| HTTP method | `POST /v1/<path>` | `POST /v1/<mount>/data/<path>` |
| Recommended | Legacy only | Preferred for new deployments |

The scripts auto-detect the path structure for KV v2 (inserts `/data/` if missing). Set `VAULT_KV_VERSION=1` explicitly for KV v1 mounts.

---

## AppRole vs Token Authentication

| Method | When to use |
| --- | --- |
| **VAULT_TOKEN** | Short-lived tokens fetched at broker start-up; use token TTL of ≤ 1 hour |
| **AppRole** | Long-running broker processes; role ID is low-sensitivity, secret ID is rotatable |

AppRole best practices:
- Set a short `secret_id_ttl` (e.g. `24h`) and rotate the secret ID regularly.
- Set `secret_id_num_uses = 1` for one-time secret IDs if the broker fetches a new one each run.
- Bind the AppRole's `token_policies` to the minimal write-only policy above.
- Enable `bound_cidr_list` on the AppRole to restrict which IP ranges can authenticate.

---

## Security Considerations

### Secret not passed as a process argument
- **CLI variant**: The Vault CLI `<key>=-` syntax reads the value from stdin. `SECRET_VALUE` is piped via `printf '%s'`, keeping it out of the process argument list visible in `ps aux`.
- **curl variant**:
  - `SECRET_VALUE` is passed to `jq` via stdin using `jq -Rs` rather than `--arg`.
  - The AppRole `VAULT_SECRET_ID_AR` is also piped through `jq -Rs` to avoid exposure as a `jq` argument.
- **PowerShell variant**: All sensitive values are held in PS variables and sent as `Invoke-RestMethod` request bodies — they do not appear as OS-level process arguments.

### TLS
- All Vault communication should use HTTPS. Only set `VAULT_SKIP_VERIFY=true` in isolated dev or test environments — never in production.
- Validate Vault's TLS certificate against a trusted CA, or pin the certificate.

### Token hygiene
- Use tokens with a short TTL. Prefer renewable tokens and let the broker renew them rather than using long-lived static tokens.
- Never log `VAULT_TOKEN` or `HCV_TOKEN`. The scripts explicitly avoid this.
- Revoke the token at broker shutdown if the broker lifecycle supports it.

### Namespace isolation
- On multi-tenant Vault clusters (Enterprise or HCP Vault Dedicated), always set `VAULT_NAMESPACE` to limit the scope of the token to the correct namespace.

### Logging
- The scripts log the Vault address, path, and key name for auditability.
- The secret **value** and the Vault token are never printed to stdout or stderr.
- Ensure the broker platform does not enable shell debug tracing (`set -x`) or PowerShell transcript logging.

---

## Example Broker Configuration

```yaml
checkout:
  script: sync-to-hashicorp-vault-curl.sh
  env:
    VAULT_ADDR:        "https://vault.example.com:8200"
    VAULT_TOKEN:       "{{ vault_sync_token }}"
    VAULT_SECRET_PATH: "secret/my-app/database"
    VAULT_SECRET_KEY:  "password"
    VAULT_KV_VERSION:  "2"
```

`SECRET_VALUE` is injected automatically by the Britive platform.
