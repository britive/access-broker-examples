# Secret Synchronization — Britive Vault → External Secret Stores

Britive Secrets Vault is the **single source of truth** for credential lifecycle: policy, versioning, rotation schedules, and access governance all live in Britive. These scripts **push the current secret value** to a downstream secret store whenever the Britive broker executes a checkout.

The Britive platform calls the broker script and injects all required values — including the secret itself — as environment variables. The script does not call back to Britive; it only writes to the destination vault. This is the same pattern used for [Active Directory password rotation](../Active%20Directory/rotate/).

---

## Supported Destinations

| Destination | CLI script | curl / REST script | PowerShell script |
| --- | --- | --- | --- |
| **AWS Secrets Manager** | `aws/sync-to-aws-secrets-manager.sh` | `aws/sync-to-aws-secrets-manager-curl.sh` | `aws/sync-to-aws-secrets-manager.ps1` |
| **Azure Key Vault** | `azure/sync-to-azure-key-vault.sh` | `azure/sync-to-azure-key-vault-curl.sh` | `azure/sync-to-azure-key-vault.ps1` |
| **HashiCorp Vault** | `hashicorp/sync-to-hashicorp-vault.sh` | `hashicorp/sync-to-hashicorp-vault-curl.sh` | `hashicorp/sync-to-hashicorp-vault.ps1` |
| **GCP Secret Manager** | `gcp/sync-to-gcp-secret-manager.sh` | `gcp/sync-to-gcp-secret-manager-curl.sh` | `gcp/sync-to-gcp-secret-manager.ps1` |

**CLI variants** — use the cloud provider's official CLI tool (`aws`, `az`, `vault`, `gcloud`). Recommended when the CLI is already installed on the broker host.

**curl / REST variants** — call the provider's HTTP API using only `curl` and `jq`. Use these in minimal container images or environments where installing the full CLI is not possible.

**PowerShell variants** — use `Invoke-RestMethod` and, where applicable, the provider's CLI. Suitable for Windows broker hosts or mixed OS environments.

---

## How It Fits Into the Broker Workflow

```text
┌─────────────────────────────────────────────────┐
│  Britive Secrets Vault                          │
│  (source of truth: rotation policy, versions,   │
│   access governance, lifecycle management)      │
└────────────────────┬────────────────────────────┘
                     │  broker checkout triggered
                     │  Britive injects SECRET_VALUE
                     │  and config as env vars
                     ▼
         ┌───────────────────────┐
         │  sync-to-*.sh / .ps1  │  ← runs on Britive broker
         └──────────┬────────────┘
                    │  writes value to destination
       ┌────────────┼────────────┬──────────────┐
       ▼            ▼            ▼              ▼
  AWS Secrets   Azure Key   HashiCorp      GCP Secret
  Manager       Vault       Vault (KV)     Manager
```

The downstream stores always reflect the latest Britive-managed value. Applications that cannot integrate directly with Britive read from their native secret store (e.g., AWS SDK reading from Secrets Manager) while Britive continues to own the rotation and governance.

---

## Common Environment Variables

All scripts expect these variables to be injected by the Britive broker:

| Variable | Description |
| --- | --- |
| `SECRET_VALUE` | The secret value to write — provided by the Britive platform |

---

## Destination-Specific Variables

### AWS Secrets Manager

| Variable | Required | Description |
| --- | --- | --- |
| `AWS_SECRET_NAME` | Yes | Name or ARN of the target secret in AWS Secrets Manager |
| `AWS_REGION` | Yes | AWS region, e.g. `us-east-1` |
| `AWS_PROFILE` | No | Named AWS CLI profile (CLI variant only) |
| `AWS_ACCESS_KEY_ID` | curl variant | AWS access key ID |
| `AWS_SECRET_ACCESS_KEY` | curl variant | AWS secret access key |
| `AWS_SESSION_TOKEN` | curl variant | STS session token (for temporary credentials) |

The CLI variant uses the standard AWS credential chain (env vars, instance profile, IRSA, etc.). The curl variant implements AWS Signature Version 4 signing in bash — requires `openssl` and `xxd`.

### Azure Key Vault

| Variable | Required | Description |
| --- | --- | --- |
| `AZURE_VAULT_URL` | Yes | Key Vault URL, e.g. `https://myvault.vault.azure.net` |
| `AZURE_SECRET_NAME` | Yes | Target secret name inside the Key Vault |
| `AZURE_TENANT_ID` | curl + PS1 | Azure AD (Entra ID) tenant ID |
| `AZURE_CLIENT_ID` | curl + PS1 | Service principal / app registration client ID |
| `AZURE_CLIENT_SECRET` | curl + PS1 | Service principal client secret |
| `AZURE_SECRET_CONTENT_TYPE` | No | Optional content-type tag, e.g. `text/plain` |
| `AZURE_SECRET_EXPIRES` | No | Optional expiry (ISO 8601 string) |

The CLI variant authenticates via the `az` CLI's existing session (managed identity, service principal, etc.).

### HashiCorp Vault

| Variable | Required | Description |
| --- | --- | --- |
| `VAULT_ADDR` | Yes | Vault server URL, e.g. `https://vault.example.com:8200` |
| `VAULT_TOKEN` | Yes (or AppRole) | Vault token with write access to the target path |
| `VAULT_SECRET_PATH` | Yes | KV path, e.g. `secret/my-app/database` |
| `VAULT_SECRET_KEY` | Yes | Key name within the KV secret, e.g. `password` |
| `VAULT_ROLE_ID` | AppRole alt. | AppRole role ID (instead of `VAULT_TOKEN`) |
| `VAULT_SECRET_ID_AR` | AppRole alt. | AppRole secret ID (instead of `VAULT_TOKEN`) |
| `VAULT_NAMESPACE` | No | Vault namespace (HCP Vault Dedicated / Enterprise) |
| `VAULT_KV_VERSION` | No | KV engine version: `1` or `2` (default: `2`) |
| `VAULT_MOUNT_PATH` | No | KV mount path (default: `secret`) |
| `VAULT_SKIP_VERIFY` | No | Set to `true` to skip TLS cert verification |

### GCP Secret Manager

| Variable | Required | Description |
| --- | --- | --- |
| `GCP_PROJECT_ID` | Yes | GCP project ID |
| `GCP_SECRET_NAME` | Yes | Secret resource name, e.g. `my-app-db-password` |
| `GCP_SA_KEY_FILE` | Auth | Path to a service account JSON key file |
| `GCP_ACCESS_TOKEN` | Auth | Pre-obtained OAuth2 access token |
| `GCP_DISABLE_PREVIOUS_VERSIONS` | No | Set to `true` to disable older versions after sync |

If neither `GCP_SA_KEY_FILE` nor `GCP_ACCESS_TOKEN` is set, the script falls back to the GCE/GKE/Cloud Run metadata server.

---

## Prerequisites Summary

| Script variant | Tools required |
| --- | --- |
| Bash CLI | `curl`, `jq`, and the provider CLI (`aws` / `az` / `vault` / `gcloud`) |
| Bash curl | `curl`, `jq`; AWS curl also needs `openssl` + `xxd`; GCP SA key also needs `openssl` + `base64` |
| PowerShell | `Invoke-RestMethod` (built-in); AWS PS1 also needs AWS CLI; GCP SA key PS1 needs PowerShell 6+ |

---

## Configuring in the Britive Broker

Assign the script as the **checkout** action on the relevant broker resource profile. Configure the destination-specific environment variables as broker parameters. `SECRET_VALUE` is injected automatically by the Britive platform.

Example broker config fragment:

```yaml
checkout:
  script: sync-to-aws-secrets-manager.sh
  env:
    AWS_SECRET_NAME: "my-app/database/password"
    AWS_REGION:      "us-east-1"
```

---

## Security Notes

- **Never log secret values.** All scripts log destination names and status but never the value of `SECRET_VALUE`.
- **Scope cloud credentials tightly.** The IAM role / service principal writing to the downstream store should have write access only to the specific secret being synced.
- **Use short-lived credentials.** Prefer instance profiles, Workload Identity, and IRSA over long-lived static keys wherever possible.

---

## Related Examples

- [Active Directory Password Rotation](../Active%20Directory/rotate/) — the broker pattern this follows
