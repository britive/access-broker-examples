# GCP Secret Manager — Secret Synchronization

Writes a secret value from the Britive broker into a **GCP Secret Manager** secret. Britive manages the credential lifecycle (rotation policy, versioning, access governance); these scripts ensure the downstream secret in GCP Secret Manager always reflects the latest value.

Each invocation **adds a new version** to the secret resource — GCP Secret Manager preserves the full version history. Use `GCP_DISABLE_PREVIOUS_VERSIONS=true` to disable older versions automatically after a successful sync.

---

## Scripts

| Script | Tooling required | Best for |
| --- | --- | --- |
| `sync-to-gcp-secret-manager.sh` | `gcloud` CLI | Broker hosts with the Google Cloud SDK installed |
| `sync-to-gcp-secret-manager-curl.sh` | `curl`, `jq`, `base64`, `openssl` | Minimal container images; no gcloud available |
| `sync-to-gcp-secret-manager.ps1` | PowerShell 6+ | Windows or Linux broker hosts (PS Core) |

---

## How It Works

1. The Britive platform calls the script at checkout time and injects all required values as environment variables.
2. The script authenticates to GCP using a service account key file, a pre-obtained access token, or the Compute Engine metadata server (for GCE, GKE, Cloud Run).
3. The script ensures the secret resource exists in Secret Manager, creating it if not.
4. The script base64-encodes `SECRET_VALUE` and adds it as a new secret version.
5. If `GCP_DISABLE_PREVIOUS_VERSIONS=true`, all previously enabled versions are disabled.

---

## Prerequisites

### All scripts
- Network access to `secretmanager.googleapis.com` (port 443)
- For SA key auth: network access to `oauth2.googleapis.com`
- The authenticating identity must have the **Secret Manager Secret Version Adder** role on the specific secret (or the project)

### CLI variant (`sync-to-gcp-secret-manager.sh`)
- **Google Cloud SDK** (`gcloud`) installed and on `PATH`
- Authentication via: application default credentials, `gcloud auth activate-service-account`, Workload Identity, or a service account key file (`GCP_SA_KEY_FILE`)

### curl variant (`sync-to-gcp-secret-manager-curl.sh`)
- `curl`, `jq`, `base64` (standard on Linux)
- For SA key authentication: also `openssl`

### PowerShell variant (`sync-to-gcp-secret-manager.ps1`)
- PowerShell **6+** (Core) — required for RSA key import via `ImportPkcs8PrivateKey`
- PowerShell 5.1 on Windows is supported only if `GCP_ACCESS_TOKEN` is pre-obtained externally

---

## Environment Variables

### Required (injected by the Britive broker)

| Variable | Description |
| --- | --- |
| `SECRET_VALUE` | The secret value to write — provided by the Britive platform |
| `GCP_PROJECT_ID` | GCP project ID that owns the Secret Manager secret |
| `GCP_SECRET_NAME` | Short secret name, e.g. `myapp-db-password` (not the full resource path) |

### Authentication — choose one

| Variable | Description |
| --- | --- |
| `GCP_SA_KEY_FILE` | Path to a service account JSON key file on the broker host |
| `GCP_ACCESS_TOKEN` | Pre-obtained OAuth2 access token (useful with Workload Identity Federation) |
| *(neither set)* | Falls back to the GCE/GKE/Cloud Run instance metadata server |

### Optional

| Variable | Default | Description |
| --- | --- | --- |
| `GCP_DISABLE_PREVIOUS_VERSIONS` | `false` | Set to `true` to disable all previously enabled versions after adding the new one |

---

## GCP IAM

Grant only the permissions needed to add new secret versions:

| Role | Description |
| --- | --- |
| `roles/secretmanager.secretVersionAdder` | Add new versions to an existing secret |
| `roles/secretmanager.secretCreator` | Create new secrets — only needed if the secret may not yet exist |

Assign at the **secret resource level** where possible, not at the project level:

```bash
gcloud secrets add-iam-policy-binding my-secret \
    --project="${GCP_PROJECT_ID}" \
    --member="serviceAccount:broker-sa@project.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretVersionAdder"
```

- Applications reading secrets need `roles/secretmanager.secretAccessor` separately — do not grant it to the broker service account.
- If `GCP_DISABLE_PREVIOUS_VERSIONS=true`, also grant `roles/secretmanager.secretVersionManager` (includes disable capability).

---

## Secret Versioning Model

GCP Secret Manager never overwrites versions — each sync call creates a new version:

```
Version 1 (ENABLED)  → initial value
Version 2 (ENABLED)  → after first sync
Version 3 (ENABLED)  → after second sync   ← latest
```

**With `GCP_DISABLE_PREVIOUS_VERSIONS=true`:**

```
Version 1 (DISABLED) → initial value
Version 2 (DISABLED) → after first sync
Version 3 (ENABLED)  → after second sync   ← latest only
```

Consumers accessing `latest` (the default) always receive the most recent enabled version. Versions can be restored, destroyed, or inspected individually via the GCP console or `gcloud secrets versions` commands.

---

## Authentication Methods

### Service account key file (`GCP_SA_KEY_FILE`)
The scripts generate a short-lived OAuth2 access token by signing a JWT with the service account private key (RS256). The token is valid for 1 hour. This works from any host with outbound HTTPS to `oauth2.googleapis.com`.

> **Important**: Service account key files are long-lived credentials. Store them only on the broker host, restrict file permissions to `600`, and rotate them on a schedule. Prefer **Workload Identity** over key files on GKE or Cloud Run.

### Workload Identity / pre-obtained token (`GCP_ACCESS_TOKEN`)
On GKE, Cloud Run, or GCE, the broker can obtain an access token from the metadata server without any key file. Set `GCP_ACCESS_TOKEN` if the token is fetched externally (e.g., via Workload Identity Federation from a non-GCP host).

### Instance metadata server (no variables set)
When neither `GCP_SA_KEY_FILE` nor `GCP_ACCESS_TOKEN` is set, the scripts query `http://metadata.google.internal/...` automatically. This is the preferred method for brokers running on GCE, GKE, or Cloud Run with the correct service account attached.

---

## Security Considerations

### Secret not passed as a process argument
- **CLI variant**: `SECRET_VALUE` is piped to `gcloud secrets versions add --data-file=-` via `printf '%s'`. It never appears as a CLI argument.
- **curl variant**:
  - `SECRET_VALUE` is piped through `base64` and then through `jq -Rs` to build the JSON payload, keeping it out of process arguments at both steps.
  - The service account private key is passed to `openssl` via process substitution (`<(printf ...)`) rather than a temp file or argument.
- **PowerShell variant**: All sensitive values are in PS variables and encoded/sent via `Invoke-RestMethod` — no OS-level process argument exposure.

### Service account key file security
- Restrict the key file to `chmod 600` (or equivalent ACL on Windows).
- Do not check the key file into source control.
- Rotate key files on a regular schedule (90 days recommended).
- Consider using **Workload Identity** or **Workload Identity Federation** to eliminate the key file entirely.

### TLS
All communication with GCP APIs is over HTTPS. None of the scripts disable TLS verification.

### Metadata server SSRF protection
On GCE/GKE, the metadata server is accessible from any process on the instance. Ensure only the broker process can reach it, or use **Workload Identity** to restrict token issuance to specific Kubernetes service accounts.

### Logging
- The scripts log the GCP project, secret name, and new version name for auditability.
- The secret **value** is never printed to stdout or stderr.
- Ensure the broker platform does not enable shell debug tracing (`set -x`) or PowerShell transcript logging.

---

## Example Broker Configuration

```yaml
checkout:
  script: sync-to-gcp-secret-manager.sh
  env:
    GCP_PROJECT_ID:  "my-gcp-project"
    GCP_SECRET_NAME: "myapp-db-password"
    GCP_SA_KEY_FILE: "/etc/broker/gcp-sa-key.json"
```

`SECRET_VALUE` is injected automatically by the Britive platform.
