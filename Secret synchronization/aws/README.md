# AWS Secrets Manager — Secret Synchronization

Writes a secret value from the Britive broker into an **AWS Secrets Manager** secret. Britive manages the credential lifecycle (rotation policy, versioning, access governance); these scripts ensure the downstream secret in AWS always reflects the latest value.

---

## Scripts

| Script | Tooling required | Best for |
| --- | --- | --- |
| `sync-to-aws-secrets-manager.sh` | AWS CLI v2 | Standard broker hosts with the CLI installed |
| `sync-to-aws-secrets-manager-curl.sh` | `curl`, `jq`, `openssl`, `xxd` | Minimal container images; no CLI available |
| `sync-to-aws-secrets-manager.ps1` | AWS CLI v2, PowerShell 5.1+ | Windows broker hosts |

---

## How It Works

1. The Britive platform calls the script at checkout time and injects all required values as environment variables.
2. The script writes `SECRET_VALUE` to the target AWS Secrets Manager secret.
3. If the secret does not yet exist, it is created automatically with a `put-secret-value` / `create-secret` fallback.

---

## Prerequisites

### All scripts
- Network access to `secretsmanager.<region>.amazonaws.com` (port 443)

### CLI variant (`sync-to-aws-secrets-manager.sh`, `.ps1`)
- **AWS CLI v2** installed and on `PATH`
- AWS credentials available via one of: environment variables, EC2/ECS instance profile, IRSA (EKS), or a named profile (`AWS_PROFILE`)

### curl variant (`sync-to-aws-secrets-manager-curl.sh`)
- `curl`, `jq`, `openssl`, `xxd` (all standard on most Linux distributions)
- Static AWS credentials (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) or temporary credentials with a session token

---

## Environment Variables

### Required (injected by the Britive broker)

| Variable | Description |
| --- | --- |
| `SECRET_VALUE` | The secret value to write — provided by the Britive platform |
| `AWS_SECRET_NAME` | Name or ARN of the target secret, e.g. `prod/myapp/db-password` |
| `AWS_REGION` | AWS region where the secret lives, e.g. `us-east-1` |

### CLI and PowerShell variant — optional

| Variable | Description |
| --- | --- |
| `AWS_PROFILE` | Named AWS CLI profile (omit to use the default credential chain) |

### curl variant — additional required

| Variable | Description |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | AWS access key ID |
| `AWS_SECRET_ACCESS_KEY` | AWS secret access key |
| `AWS_SESSION_TOKEN` | STS session token — required when using temporary credentials (IAM role assumed via STS, IRSA, etc.) |

---

## IAM Permissions

The identity used to run these scripts needs only the minimum permissions required:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:PutSecretValue",
        "secretsmanager:CreateSecret"
      ],
      "Resource": "arn:aws:secretsmanager:<region>:<account>:secret:<secret-name>*"
    }
  ]
}
```

- Scope the `Resource` ARN to the specific secret(s) being synced — never use `*`.
- If the secret already exists, `CreateSecret` is not needed; remove it once the secret is provisioned.
- Consumers reading the secret need `secretsmanager:GetSecretValue` separately — do not grant it to the sync identity.

---

## Security Considerations

### Secret not passed as a process argument
Passing a secret as a CLI argument (`--secret-string "mypassword"`) makes it visible in `ps aux` for the duration of the process. These scripts avoid that:

- **CLI variants**: The secret is written to a `chmod 600` temp file and passed as `--secret-string file://<path>`. The temp file is removed by a `trap`/`finally` block regardless of success or failure.
- **curl variant**: The JSON request body is built using `jq -Rs` which reads `SECRET_VALUE` from stdin rather than passing it as a `--arg`, keeping it out of the `jq` process argument list.

### TLS in transit
All communication with AWS Secrets Manager is over HTTPS. The curl variant does not disable TLS verification (`--insecure` is never used).

### Credential scope
- Prefer **IRSA** (IAM Roles for Service Accounts on EKS) or **EC2/ECS instance profiles** over long-lived access keys.
- If static keys are unavoidable, use **STS AssumeRole** to obtain short-lived credentials and set `AWS_SESSION_TOKEN`.
- Never share the write identity's credentials with the applications reading the secret.

### Logging
- The scripts log the secret **name** and region for auditability.
- The secret **value** (`SECRET_VALUE`) is never printed to stdout or stderr.
- Ensure the broker platform does not enable shell debug tracing (`set -x`) or PowerShell transcript logging, as these would capture all variable expansions.

### Rotation and versioning
AWS Secrets Manager keeps previous versions (labelled `AWSPREVIOUS`) automatically. Applications using `GetSecretValue` without a `VersionStage` will always receive the latest version. Older versions are garbage-collected by AWS after a configurable number of days.

---

## Example Broker Configuration

```yaml
checkout:
  script: sync-to-aws-secrets-manager.sh
  env:
    AWS_SECRET_NAME: "prod/myapp/db-password"
    AWS_REGION:      "us-east-1"
```

`SECRET_VALUE` is injected automatically by the Britive platform.
