# Lab — Azure Key Vault

Test the `azure/` sync scripts against a live Azure Key Vault secret.

## What gets created

| Resource | Name (default) |
| --- | --- |
| Resource group | `britive-lab-rg` |
| Key Vault (RBAC mode) | `britive-lab-<random>` |
| Service principal | `britive-lab-sp` |
| Role assignment | Key Vault Secrets Officer on the vault |
| Key Vault secret | `britive-lab-test-secret` |

The Key Vault name includes a random suffix to satisfy Azure's global-uniqueness
requirement. `setup.sh` records the generated name in `.env`.

---

## Prerequisites

- Azure CLI installed: [install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- Logged in with an account that has **Contributor** + **User Access Administrator**
  on the subscription (needed to create resource groups and assign RBAC roles):

```bash
az login
az account set --subscription "YOUR_SUBSCRIPTION"
```

---

## Option A — Console walkthrough

### 1. Create a resource group

1. Open **Azure Portal → Resource groups → Create**.
2. Name: `britive-lab-rg`, Region: `East US` (or your preferred region).
3. Click **Review + create → Create**.

### 2. Create a Key Vault

1. Open **Key Vaults → Create**.
2. Resource group: `britive-lab-rg`.
3. Name: `britive-lab-<something-unique>` (3–24 chars, lowercase only).
4. Region: same as the resource group.
5. Under **Access configuration**, select **Azure role-based access control (RBAC)**.
6. Click through to **Review + create → Create**.
7. Note the **Vault URI** (e.g. `https://britive-lab-abc123.vault.azure.net`).

### 3. Create a service principal

```bash
# In the Azure CLI or Cloud Shell
az ad sp create-for-rbac \
    --name "britive-lab-sp" \
    --skip-assignment
```

Note the output `appId`, `password`, and `tenant`.

### 4. Assign the role

1. Open the Key Vault → **Access control (IAM) → Add role assignment**.
2. Role: **Key Vault Secrets Officer**.
3. Members: search for `britive-lab-sp`.
4. Review + assign.

### 5. Create the initial secret

1. Open the Key Vault → **Secrets → Generate/Import**.
2. Name: `britive-lab-test-secret`, Value: `initial-placeholder`.
3. Click **Create**.

### 6. Create `.env`

Create `labs/azure/.env` (never commit this):

```bash
AZURE_TENANT_ID=<tenant from SP creation>
AZURE_CLIENT_ID=<appId from SP creation>
AZURE_CLIENT_SECRET=<password from SP creation>
AZURE_VAULT_URL=https://britive-lab-abc123.vault.azure.net
AZURE_SECRET_NAME=britive-lab-test-secret
VAULT_NAME=britive-lab-abc123
LAB_RESOURCE_GROUP=britive-lab-rg
LAB_SP_APP_ID=<appId from SP creation>
LAB_SUBSCRIPTION_ID=<your subscription ID>
```

---

## Option B — CLI quickstart

```bash
# Optional overrides
export AZURE_LOCATION=eastus
export RG_NAME=britive-lab-rg

./setup.sh
```

`setup.sh` creates all resources and writes `.env`. It may take ~15 seconds for
RBAC propagation before the initial secret can be created.

---

## Run the tests

```bash
./test-sync.sh
```

The test script logs in the Azure CLI as the service principal before running the
CLI variant, then uses the SP credentials directly for the curl variant.

Expected output:

```text
[...] Test value : britive-lab-azure-1700000001
[...] Vault URL  : https://britive-lab-abc123.vault.azure.net
[...] Secret name: britive-lab-test-secret

=== Variant 1: bash CLI (sync-to-azure-key-vault.sh) ===
[...] Writing secret to Azure Key Vault...
[...] Done.
  [PASS] bash CLI variant

=== Variant 2: bash curl (sync-to-azure-key-vault-curl.sh) ===
[...] Obtaining bearer token...
[...] Writing secret value...
[...] Done.
  [PASS] bash curl variant

=== Variant 3: PowerShell (sync-to-azure-key-vault.ps1) ===
[...] Done.
  [PASS] PowerShell variant

──────────────────────────────────────────
All tests passed.
```

### Manual verification

```bash
source .env
az keyvault secret show \
    --vault-name "${VAULT_NAME}" \
    --name       "${AZURE_SECRET_NAME}" \
    --query      'value' \
    --output     tsv
```

---

## Cleanup

```bash
./teardown.sh
```

Deletes the service principal, resource group (which removes the Key Vault and
all secrets), and attempts to purge the soft-deleted vault. Removes `.env`.

> **Note:** Azure Key Vault soft-delete retains a recoverable copy for 7–90 days
> even after the resource group is deleted. The teardown script attempts a purge,
> but purge permissions depend on vault configuration.

---

## Security notes

- The service principal is scoped to **Key Vault Secrets Officer** on the single
  vault — it cannot access other vaults or Azure resources.
- The bash CLI variant writes the secret to a temp file (`chmod 600`) and passes
  `--file` to the Azure CLI, avoiding process-argument exposure.
- The curl variant passes `AZURE_CLIENT_SECRET` via `--data-urlencode @file`
  and builds the secret payload with `jq -Rs` reading from stdin.
- Client secrets are stored only in `.env` (mode `600`). Rotate or delete them
  with `teardown.sh` when finished.
