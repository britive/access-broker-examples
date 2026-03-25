# Azure Key Vault — Secret Synchronization

Writes a secret value from the Britive broker into an **Azure Key Vault** secret. Britive manages the credential lifecycle (rotation policy, versioning, access governance); these scripts ensure the downstream secret in Azure Key Vault always reflects the latest value.

---

## Scripts

| Script | Tooling required | Best for |
| --- | --- | --- |
| `sync-to-azure-key-vault.sh` | Azure CLI (`az`) | Broker hosts with the CLI installed; supports all Azure auth methods |
| `sync-to-azure-key-vault-curl.sh` | `curl`, `jq` | Minimal container images; service principal auth only |
| `sync-to-azure-key-vault.ps1` | PowerShell 5.1+ | Windows broker hosts; service principal auth |

---

## How It Works

1. The Britive platform calls the script at checkout time and injects all required values as environment variables.
2. The script authenticates to Azure AD and obtains a bearer token scoped to `https://vault.azure.net`.
3. The script writes `SECRET_VALUE` to the named secret in the target Key Vault using the Key Vault REST API (API version 7.4).
4. If the secret does not yet exist, Azure Key Vault creates it automatically on first `PUT`.

---

## Prerequisites

### All scripts

- Network access to `login.microsoftonline.com` (port 443) and `<vault-name>.vault.azure.net` (port 443)
- The authenticating identity must have the **Key Vault Secrets Officer** role (or a custom role with `Microsoft.KeyVault/vaults/secrets/setSecret/action`) on the target vault

### CLI variant (`sync-to-azure-key-vault.sh`)

- **Azure CLI v2** installed and on `PATH`
- Authentication pre-configured via: `az login`, Managed Identity, service principal environment variables (`AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID`), or Workload Identity

### curl and PowerShell variants

- Service principal with a client secret (`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`)
- For managed identity or federated identity, use the CLI variant instead

---

## Environment Variables

### Required (injected by the Britive broker)

| Variable | Description |
| --- | --- |
| `SECRET_VALUE` | The secret value to write — provided by the Britive platform |
| `AZURE_VAULT_URL` | Key Vault URL, e.g. `https://myvault.vault.azure.net` |
| `AZURE_SECRET_NAME` | Target secret name inside the Key Vault |

### curl and PowerShell variants — additional required

| Variable | Description |
| --- | --- |
| `AZURE_TENANT_ID` | Azure AD (Entra ID) tenant ID (GUID) |
| `AZURE_CLIENT_ID` | Service principal / app registration client ID (GUID) |
| `AZURE_CLIENT_SECRET` | Service principal client secret |

### Optional

| Variable | Description |
| --- | --- |
| `AZURE_SECRET_CONTENT_TYPE` | Content-type tag applied to the secret, e.g. `text/plain` |
| `AZURE_SECRET_EXPIRES` | Secret expiry: ISO 8601 string (`.sh`) or Unix timestamp integer (curl) |

---

## Azure RBAC

Grant only the permissions needed for writing secrets:

| Role | Scope | Notes |
| --- | --- | --- |
| **Key Vault Secrets Officer** | Specific Key Vault | Allows set + delete; remove delete if not needed |
| Custom role with `setSecret` only | Specific Key Vault | Principle of least privilege |

- Assign the role at the **Key Vault scope**, not the subscription or resource group.
- Applications reading secrets need the **Key Vault Secrets User** role — do not grant write permissions to the consumer identity.
- If the Key Vault uses **access policies** instead of Azure RBAC, grant only `Set` under Secret Permissions.

---

## Security Considerations

### Secret not passed as a process argument

- **CLI variant**: The secret is written to a `chmod 600` temp file and passed with `az keyvault secret set --file <path>`. The temp file is removed by a `trap` block regardless of success or failure.
- **curl variant**:
  - `AZURE_CLIENT_SECRET` is written to a `chmod 600` temp file and passed using curl's `--data-urlencode "client_secret@<file>"` form, which reads the value from the file and URL-encodes it without exposing it as a command-line argument.
  - `SECRET_VALUE` is passed to `jq` via stdin using `jq -Rs` rather than `--arg`, keeping it out of the `jq` process argument list.
- **PowerShell variant**: Secrets are held in PS variables and sent as the body of `Invoke-RestMethod` calls — they do not appear as OS-level process arguments.

### TLS in transit

All communication with Azure AD and Key Vault is over HTTPS. None of the scripts disable TLS certificate verification.

### Credential scope for the service principal

- Use a dedicated service principal for secret synchronization — do not reuse an application identity.
- Set the client secret to expire and rotate it on a schedule. Consider using **certificate-based authentication** (no client secret at all) for higher-assurance environments.
- The service principal only needs `setSecret` on the specific Key Vault, not across the subscription.

### Key Vault network controls

- Enable **Key Vault Firewall** and restrict access to the broker host's IP range or subnet, rather than allowing all networks.
- For highest isolation, use **Private Endpoint** for the Key Vault and ensure the broker host is on the same virtual network.

### Logging

- The scripts log the vault URL and secret name for auditability.
- The secret **value** and the client secret are never printed to stdout or stderr.
- Ensure the broker platform does not enable shell debug tracing (`set -x`) or PowerShell transcript logging.

### Secret versioning

Azure Key Vault maintains the full version history of each secret. Previous versions are accessible via their version ID but are marked inactive. Consumers using `GetSecret` without a version ID always receive the current version. Versions can be individually disabled or deleted if required.

---

## Example Broker Configuration

```yaml
checkout:
  script: sync-to-azure-key-vault-curl.sh
  env:
    AZURE_VAULT_URL:       "https://myvault.vault.azure.net"
    AZURE_SECRET_NAME:     "myapp-db-password"
    AZURE_TENANT_ID:       "{{ azure_tenant_id }}"
    AZURE_CLIENT_ID:       "{{ sp_client_id }}"
    AZURE_CLIENT_SECRET:   "{{ sp_client_secret }}"
```

`SECRET_VALUE` is injected automatically by the Britive platform.
