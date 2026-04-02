# Lab — HashiCorp Vault

Test the `hashicorp/` sync scripts against a local Vault dev server running in
Docker. No Vault account or cloud credentials are required.

## What gets created

| Resource | Details |
| --- | --- |
| Docker container | `britive-lab-vault` (hashicorp/vault:latest, dev mode) |
| KV v2 mount | `secret/` |
| Vault policy | `britive-lab-policy` |
| Vault token | Scoped token with 24-hour TTL |
| AppRole role | `britive-lab-approle` |
| KV secret | `secret/britive-lab/test`  key: `password` |

> **Dev mode note:** Vault dev mode stores all data in memory. Everything is
> lost when the container stops — no persistence, no unsealing required.
> Do not use dev mode in production.

---

## Prerequisites

- **Docker** with Compose v2 plugin (or `docker-compose` v1):
  [install Docker](https://docs.docker.com/get-docker/)
- **Vault CLI** (for setup provisioning):
  [install Vault](https://developer.hashicorp.com/vault/downloads)
- `jq` installed

Check your setup:

```bash
docker compose version    # or: docker-compose version
vault version
jq --version
```

---

## Option A — Docker quickstart (recommended)

```bash
./setup.sh
```

This starts the container, enables KV v2, creates a policy + scoped token,
sets up AppRole, and writes `.env`.

The Vault UI is available at `http://localhost:8200/ui` — log in with the
root token `britive-lab-root-token`.

---

## Option B — Console / manual setup

### Start Vault in dev mode manually

```bash
docker compose up -d
```

### Provision using the Vault UI

1. Open `http://localhost:8200/ui` and sign in with token `britive-lab-root-token`.
2. Go to **Secrets Engines → Enable New Engine → KV** → path `secret`, version 2.
3. Go to **Policies → Create ACL policy**, name `britive-lab-policy`:

```hcl
path "secret/data/britive-lab/*" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/britive-lab/*" {
  capabilities = ["read", "list"]
}
```

4. Go to **Access → Auth Methods → Enable method → AppRole**.
5. Create a role `britive-lab-approle` associated with `britive-lab-policy`.
6. Retrieve the `role_id` and generate a `secret_id` via the API or UI.
7. Go to **Access → Tokens → Create token** with policy `britive-lab-policy`.

### Option B via CLI

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=britive-lab-root-token

# Enable KV v2 (already enabled in dev mode)
vault secrets enable -path=secret kv-v2

# Write an initial secret
vault kv put secret/britive-lab/test password=initial-placeholder

# Create policy
vault policy write britive-lab-policy - <<'EOF'
path "secret/data/britive-lab/*" {
  capabilities = ["create", "update", "read"]
}
EOF

# Create scoped token
vault token create -policy=britive-lab-policy -ttl=24h

# AppRole
vault auth enable approle
vault write auth/approle/role/britive-lab-approle policies=britive-lab-policy
vault read  auth/approle/role/britive-lab-approle/role-id
vault write -force auth/approle/role/britive-lab-approle/secret-id
```

### Create `.env` manually

Create `labs/hashicorp/.env`:

```bash
VAULT_ADDR=http://127.0.0.1:8200
VAULT_TOKEN=<scoped token from above>
VAULT_ROLE_ID=<role_id>
VAULT_SECRET_ID_AR=<secret_id>
VAULT_SECRET_PATH=secret/britive-lab/test
VAULT_SECRET_KEY=password
VAULT_KV_VERSION=2
LAB_ROOT_TOKEN=britive-lab-root-token
LAB_APPROLE_NAME=britive-lab-approle
LAB_POLICY_NAME=britive-lab-policy
```

---

## Using HCP Vault Dedicated instead of Docker

If you have an HCP Vault cluster:

1. Skip `setup.sh`.
2. Populate `.env` with your HCP Vault address, namespace, and a token/AppRole.
3. Add `VAULT_NAMESPACE=admin` (or your namespace) to `.env`.
4. The sync scripts and `test-sync.sh` will work unchanged.

---

## Run the tests

```bash
./test-sync.sh
```

The test exercises four variants: bash CLI (token), curl (token),
curl (AppRole), and PowerShell (if `pwsh` is present).

Expected output:

```text
[...] Vault     : http://127.0.0.1:8200
[...] Secret    : secret/britive-lab/test  key: password

=== Variant 1: bash CLI — token auth ===
[...] Writing secret...
[...] Done.
  [PASS] bash CLI (token auth)

=== Variant 2: bash curl — token auth ===
[...] Writing secret via REST...
  [PASS] bash curl (token auth)

=== Variant 3: bash curl — AppRole auth ===
[...] Authenticating via AppRole...
[...] Writing secret via REST...
  [PASS] bash curl (AppRole auth)

=== Variant 4: PowerShell ===
  [PASS] PowerShell variant

──────────────────────────────────────────
All tests passed.
```

### Manual verification

```bash
source .env
export VAULT_ADDR VAULT_TOKEN
vault kv get -field=password secret/britive-lab/test
```

---

## Cleanup

```bash
./teardown.sh
```

Stops the Docker container (all in-memory data is gone) and removes `.env`.

---

## Security notes

- The lab token is scoped to `secret/britive-lab/*` only — it cannot read or
  write other Vault paths.
- The bash CLI variant passes the secret to Vault via stdin (`key=-`), keeping
  it out of the process argument list.
- The curl variant uses `jq -Rs` to build payloads from stdin for both the
  secret value and the AppRole `secret_id`.
- The dev-mode root token (`britive-lab-root-token`) is fixed and published.
  This is acceptable only for local lab use — never use fixed root tokens in
  production.
