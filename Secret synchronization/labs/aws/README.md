# Lab — AWS Secrets Manager

Test the `aws/` sync scripts against a live AWS Secrets Manager secret.

## What gets created

| Resource | Name (default) |
| --- | --- |
| IAM policy | `britive-lab-policy` |
| IAM user | `britive-lab-user` |
| IAM access key | (generated) |
| Secrets Manager secret | `britive-lab/test-secret` |

All resources are scoped to a single secret ARN — the IAM policy grants no
other AWS permissions.

---

## Option A — Console walkthrough

Use this path if you prefer to set things up manually in the AWS Console.

### 1. Create the Secrets Manager secret

1. Open **AWS Console → Secrets Manager → Store a new secret**.
2. Choose **Other type of secret** → **Plaintext**.
3. Enter `initial-placeholder` as the initial value.
4. Click **Next** and set the name to `britive-lab/test-secret`.
5. Leave rotation disabled, click through to **Store**.
6. Note the full **Secret ARN** from the secret's detail page.

### 2. Create an IAM policy

1. Open **IAM → Policies → Create policy**.
2. Switch to the **JSON** editor and paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "BritiveLab",
    "Effect": "Allow",
    "Action": [
      "secretsmanager:PutSecretValue",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ],
    "Resource": "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:britive-lab/test-secret*"
  }]
}
```

3. Replace `REGION` and `ACCOUNT_ID`. Click **Next**, name it `britive-lab-policy`, and save.

### 3. Create an IAM user with an access key

1. Open **IAM → Users → Create user**.
2. Name: `britive-lab-user`. Skip console access.
3. On the **Permissions** step, choose **Attach policies directly** → search for and select `britive-lab-policy`.
4. Complete creation, then open the user → **Security credentials → Create access key**.
5. Choose **Other**, create, and note the **Access Key ID** and **Secret Access Key** (shown only once).

### 4. Create `.env`

Create `labs/aws/.env` (never commit this):

```bash
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1
AWS_SECRET_NAME=britive-lab/test-secret
LAB_IAM_USER=britive-lab-user
LAB_IAM_POLICY_ARN=arn:aws:iam::ACCOUNT_ID:policy/britive-lab-policy
```

---

## Option B — CLI quickstart

```bash
# Optional: override defaults before running
export AWS_REGION=us-east-1
export SECRET_NAME=britive-lab/test-secret

./setup.sh
```

`setup.sh` creates all resources and writes `.env` automatically.

---

## Run the tests

```bash
./test-sync.sh
```

Expected output:

```text
[...] Test value: britive-lab-aws-1700000001
[...] Target    : britive-lab/test-secret (us-east-1)

=== Variant 1: bash CLI (sync-to-aws-secrets-manager.sh) ===
[...] Writing secret to AWS Secrets Manager...
[...] Done.
  [PASS] bash CLI variant

=== Variant 2: bash curl (sync-to-aws-secrets-manager-curl.sh) ===
[...] Signing request (SigV4)...
[...] Done.
  [PASS] bash curl variant

=== Variant 3: PowerShell (sync-to-aws-secrets-manager.ps1) ===
[...] Done.
  [PASS] PowerShell variant

──────────────────────────────────────────
All tests passed.
```

### Manual verification

```bash
source .env
aws secretsmanager get-secret-value \
    --secret-id "${AWS_SECRET_NAME}" \
    --region    "${AWS_REGION}" \
    --query     'SecretString' \
    --output    text
```

---

## Cleanup

```bash
./teardown.sh
```

Deletes the IAM user, policy, access keys, and the Secrets Manager secret
(force-delete — bypasses the 7-day recovery window). Removes `.env`.

---

## Security notes

- The IAM policy restricts access to a single secret ARN. The lab user cannot
  read or write any other AWS resource.
- Access keys are stored only in `.env` (mode `600`). Delete them with
  `teardown.sh` when finished.
- The bash CLI variant uses `file://` to pass the secret to the AWS CLI,
  keeping it out of the process argument list.
- The curl variant signs requests with SigV4 using `openssl` — no credentials
  are sent in plaintext.
