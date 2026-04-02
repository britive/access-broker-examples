# Secret Sync Labs

Hands-on labs to provision test infrastructure, run the synchronization scripts
against a live endpoint, verify the result, and tear everything down cleanly.

Each lab simulates exactly what the Britive broker does at runtime: it sets the
required environment variables and calls the sync script — no Britive account or
broker is needed to run the tests.

## Available labs

| Lab | Destination | Auth used in lab |
| --- | --- | --- |
| [aws/](aws/) | AWS Secrets Manager | IAM user with scoped access key |
| [azure/](azure/) | Azure Key Vault | Service principal (client credentials) |
| [hashicorp/](hashicorp/) | HashiCorp Vault | Vault token (local Docker dev server) |
| [gcp/](gcp/) | GCP Secret Manager | Service account key file |

## Prerequisites (all labs)

- Bash 4+ — macOS ships Bash 3; upgrade with `brew install bash`
- `jq` — `brew install jq` / `apt install jq`
- `curl` — pre-installed on most systems
- PowerShell 7+ (`pwsh`) — optional; required only for the `.ps1` variant test
- Cloud CLI for your chosen lab (see each lab's README)

## Lab structure

Each lab directory contains:

| File | Purpose |
| --- | --- |
| `README.md` | Console walkthrough + CLI quickstart + expected output |
| `setup.sh` | Creates cloud resources and writes a `.env` credential file |
| `test-sync.sh` | Sources `.env`, sets `SECRET_VALUE`, runs all script variants, verifies |
| `teardown.sh` | Deletes every resource created by `setup.sh` |

## Workflow

```text
./setup.sh
    └─▶ creates cloud resources
    └─▶ writes .env (credentials + resource names)

./test-sync.sh
    └─▶ sources .env
    └─▶ exports SECRET_VALUE="britive-lab-test-<timestamp>"
    └─▶ runs bash CLI variant  → verifies
    └─▶ runs bash curl variant → verifies
    └─▶ runs PowerShell variant (if pwsh present) → verifies

./teardown.sh
    └─▶ sources .env
    └─▶ deletes all provisioned resources
    └─▶ removes .env
```

## Security

- `setup.sh` writes credentials to a `.env` file in the lab directory.
- `.env` files and SA key files are listed in `.gitignore` — **never commit them**.
- `teardown.sh` removes `.env` and any local credential files after cleanup.
- Lab resources use least-privilege IAM/RBAC scoped to the test secret only.

## Quick start

```bash
cd labs/<destination>      # e.g. labs/aws
./setup.sh                 # one-time provisioning (~1 min)
./test-sync.sh             # run all variants and verify
./teardown.sh              # clean up all resources
```
