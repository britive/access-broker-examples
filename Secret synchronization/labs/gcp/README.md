# Lab — GCP Secret Manager

Test the `gcp/` sync scripts against a live GCP Secret Manager secret.

## What gets created

| Resource | Name (default) |
| --- | --- |
| GCP API | `secretmanager.googleapis.com` (enabled) |
| Service account | `britive-lab-sa@PROJECT.iam.gserviceaccount.com` |
| SA key file | `labs/gcp/sa-key.json` |
| IAM bindings on secret | `secretVersionAdder`, `viewer`, `secretVersionManager` |
| Secret Manager secret | `britive-lab-test-secret` |
| Initial secret version | `initial-placeholder` |

IAM is bound at the **individual secret level** — the service account cannot
access any other secrets or GCP resources.

---

## Prerequisites

- gcloud CLI installed and authenticated:
  [install gcloud](https://cloud.google.com/sdk/docs/install)
- Active project with billing enabled:

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

- The authenticated account needs:
  - `roles/secretmanager.admin` (to create secrets and bind IAM)
  - `roles/iam.serviceAccountAdmin` (to create the service account)
  - `roles/iam.serviceAccountKeyAdmin` (to create the SA key)

---

## Option A — Console walkthrough

### 1. Enable the Secret Manager API

1. Open **GCP Console → APIs & Services → Enable APIs and Services**.
2. Search for **Secret Manager API** and click **Enable**.

### 2. Create a service account

1. Open **IAM & Admin → Service Accounts → Create Service Account**.
2. Name: `britive-lab-sa`, ID: `britive-lab-sa`.
3. Skip the optional role assignment steps (you'll bind at the secret level).
4. Click **Done**.

### 3. Create a service account key

1. Click the service account → **Keys → Add Key → Create new key**.
2. Choose **JSON** → **Create**.
3. Save the downloaded file as `labs/gcp/sa-key.json`.
4. Run: `chmod 600 labs/gcp/sa-key.json`

### 4. Create the secret

1. Open **Secret Manager → Create Secret**.
2. Name: `britive-lab-test-secret`.
3. Under **Secret value**, enter `initial-placeholder`.
4. Leave replication as **Automatic**.
5. Click **Create Secret**.

### 5. Grant the service account access to the secret

1. Open the `britive-lab-test-secret` detail page.
2. Click **Permissions → Grant Access**.
3. Add principal: `britive-lab-sa@YOUR_PROJECT.iam.gserviceaccount.com`.
4. Assign roles:
   - `Secret Manager Secret Version Adder`
   - `Secret Manager Viewer`
   - `Secret Manager Secret Version Manager` (needed for disabling old versions)
5. Click **Save**.

### 6. Create `.env`

Create `labs/gcp/.env` (never commit this):

```bash
GCP_PROJECT_ID=your-project-id
GCP_SECRET_NAME=britive-lab-test-secret
GCP_SA_KEY_FILE=/absolute/path/to/labs/gcp/sa-key.json
LAB_SA_EMAIL=britive-lab-sa@your-project-id.iam.gserviceaccount.com
```

---

## Option B — CLI quickstart

```bash
# Optional overrides
export GCP_PROJECT_ID=your-project-id
export SECRET_NAME=britive-lab-test-secret

./setup.sh
```

`setup.sh` enables the API, creates the SA, creates a key, creates the secret,
binds IAM at the secret level, and writes `.env`.

---

## Run the tests

```bash
./test-sync.sh
```

Each variant adds a new version to the secret. GCP Secret Manager preserves
all versions — the test reads back the `latest` alias to verify.

Expected output:

```text
[...] Project : your-project-id
[...] Secret  : britive-lab-test-secret

=== Variant 1: bash CLI (sync-to-gcp-secret-manager.sh) ===
[...] Adding new secret version...
[...] Done.
  [PASS] bash CLI variant

=== Variant 2: bash curl (sync-to-gcp-secret-manager-curl.sh) ===
[...] Generating access token from SA key...
[...] Adding new secret version via REST...
[...] Done.
  [PASS] bash curl variant

=== Variant 3: PowerShell (sync-to-gcp-secret-manager.ps1) ===
[...] Done.
  [PASS] PowerShell variant

──────────────────────────────────────────
All tests passed.
```

### Manual verification

```bash
source .env
gcloud secrets versions access latest \
    --secret="${GCP_SECRET_NAME}" \
    --project="${GCP_PROJECT_ID}"
```

### Testing version disabling

To verify the `GCP_DISABLE_PREVIOUS_VERSIONS` feature:

```bash
source .env
export GCP_DISABLE_PREVIOUS_VERSIONS=true
export SECRET_VALUE="test-with-disable-$(date +%s)"
bash ../../gcp/sync-to-gcp-secret-manager.sh

# Check version states — only the latest should be ENABLED
gcloud secrets versions list "${GCP_SECRET_NAME}" \
    --project="${GCP_PROJECT_ID}"
```

---

## Cleanup

```bash
./teardown.sh
```

Destroys all secret versions, deletes the secret, deletes the SA key and
service account, and removes `sa-key.json` and `.env`.

---

## Security notes

- IAM is granted at the **individual secret** level, not the project level —
  the service account cannot access other secrets.
- The SA key file (`sa-key.json`) is sensitive. It is stored with `chmod 600`
  and listed in `.gitignore`. Delete it with `teardown.sh`.
- The bash CLI variant pipes the secret value via stdin (`--data-file=-`),
  keeping it out of the process argument list.
- The curl variant generates a short-lived OAuth2 token by signing a JWT with
  the SA private key using `openssl` — the token expires in 1 hour.
- On GCE/GKE, omit `GCP_SA_KEY_FILE` entirely; the scripts will use the
  instance metadata server for auth (no key file on disk).
