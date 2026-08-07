# AWS Secrets Manager Rotation

Replaces the value held in a Secrets Manager secret with one Britive generated,
then proves the replacement is what consumers now read.

Run by Britive's **secret rotation** module — a schedule or an on-demand
rotation — not by a profile checkout.

## Which script

| | `rotate-secret-value.sh` | `rotate-secret-with-target.sh` |
|---|---|---|
| System of record | the **secret** | the **account** behind it |
| Use for | API keys, shared tokens, values some other process re-registers | database logins, service accounts |
| Secret shape | JSON object or plaintext | JSON object only (needs a username) |
| Extra input | — | `SECRET_TARGET_HOOK` |

Rotating only the secret when a real account sits behind it leaves the secret
advertising a password the target never accepted. Every consumer then fails to
authenticate, and nothing about the secret says why.

For Active Directory neither is needed:
[`../../../Active Directory/rotate/rotate-ad-account-aws-secret.sh`](../../../Active%20Directory/rotate/rotate-ad-account-aws-secret.sh)
already does both phases natively over LDAPS.

## The password always comes from Britive

`AWS_NEW_PASSWORD` is **required**. Both scripts fail immediately if it is unset,
and neither can generate a password.

Britive's rotation module generates the value and injects it when the attribute
is configured on the rotation in the console. A password generated inside the
script would exist only in that process: the platform could neither store it nor
vend it afterwards, so the rotated credential would be lost the moment the script
exited.

---

## `rotate-secret-value.sh`

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AWS_SECRET` | Yes | — | The secret's **name or full ARN** — either one |
| `AWS_NEW_PASSWORD` | Yes | — | The new value, injected by Britive |
| `AWS_REGION` | Conditional | — | Required when `AWS_SECRET` is a name; a full ARN carries its own region |
| `AWS_SECRET_KEY` | No | `password` | JSON key to patch |
| `AWS_SECRET_MODE` | No | `auto` | `auto` / `json-key` / `plaintext` |
| `ALLOW_SERVICE_OWNED` | No | `false` | `true` to rotate a secret owned by another AWS service |
| `ROTATE_VERBOSE` | No | `false` | `true` logs progress live instead of buffering it |

`AWS_SECRET` goes straight to `--secret-id`, which accepts both forms. The scan
publishes the name as the identity id and the ARN in the `secret_arn` attribute,
so whichever is to hand works. The emitted `secret_arn` is always the canonical
one from `DescribeSecret`, not whatever was passed in.

The broker also injects the resource's attributes as `RESOURCE_AWS_SECRET` and
`RESOURCE_AWS_REGION`; both are read as fallbacks.

### Modes

| Mode | Behaviour |
|---|---|
| `auto` | Inspect the current value: a JSON object is patched at `AWS_SECRET_KEY` with every other field preserved; anything else is replaced wholesale |
| `json-key` | Require a JSON object; refuse a plaintext secret rather than overwrite it |
| `plaintext` | Replace the whole value. **Destructive** on a JSON secret — every other field is lost, which is why it must be asked for by name |

### Output

```
secret_arn=arn:aws:secretsmanager:us-west-2:123456789012:secret:app/db-AbCdEf
secret_name=app/db
region=us-west-2
mode=json-key
secret_key=password
preserved_keys=host, port, username, password
new_version=7f3c...
rotated=true
verified=true
```

The value itself is never emitted — consumers read it from Secrets Manager, and
this output lands in the broker log.

---

## `rotate-secret-with-target.sh`

Changes the target **first**, the secret **second**. The reverse order would
advertise a password the target has not accepted, and a rejected change (password
policy, history, minimum age) would leave the secret permanently wrong with no
way to tell from the secret alone. The window where the account has the new
password and the secret still serves the old one is bounded by one API call.

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AWS_SECRET_ARN` | Yes | — | ARN (or name) of the secret |
| `AWS_NEW_PASSWORD` | Yes | — | The new value, injected by Britive |
| `SECRET_TARGET_HOOK` | Yes | — | Path to an executable that applies the password to the real account |
| `AWS_REGION` | Conditional | — | Required when a name is used instead of an ARN |
| `AWS_SECRET_KEY` | No | `password` | JSON key holding the password |
| `SECRET_USERNAME_KEY` | No | `username` | JSON key holding the account name |
| `HOOK_TIMEOUT` | No | `120` | Seconds the hook may run |
| `ALLOW_SERVICE_OWNED` | No | `false` | `true` to rotate a service-owned secret |

### The hook contract

`SECRET_TARGET_HOOK` is an executable the script runs exactly once:

- Receives the new password on **stdin**, and nothing else — not `argv` (visible
  in `/proc/<pid>/cmdline`), not the environment (inherited by anything it spawns)
- Gets `SECRET_ARN`, `SECRET_NAME`, `SECRET_USERNAME` and `AWS_REGION` in its
  environment, plus the `RESOURCE_*` attributes already in scope
- **Exit 0** means the target accepted the password and it is live **now** — only
  then is the secret written
- **Exit non-zero** means nothing is written; its stderr (first 500 chars) is
  quoted in the failure
- Must be **idempotent**: a rotation retried after a lost response runs it again

```sh
#!/bin/bash
set -euo pipefail
read -r NEW_PASSWORD          # stdin, nothing else

mysql --host "$RESOURCE_HOST" --user admin \
  -e "ALTER USER '${SECRET_USERNAME}'@'%' IDENTIFIED BY '${NEW_PASSWORD}';"
```

The hook runs with the broker's credentials, so the script refuses one that is
world-writable.

### When the two sides disagree

If the secret write fails after the target changed, the script exits non-zero and
says `DIVERGED`, naming both sides. That is a real break needing a manual fix; it
is never reported as success.

---

## Both scripts

- Refuse a secret scheduled for deletion
- Refuse a service-owned secret unless `ALLOW_SERVICE_OWNED=true`
- Warn when AWS-native rotation is also enabled — the next Lambda run overwrites
  whatever Britive writes
- Stage the new value in a `0600` file passed as `file://`, never on the command
  line, and shred the temp directory on exit
- Pass a `--client-request-token`, so a retry after a lost response returns the
  same version instead of creating a second one
- **Verify by reading `AWSCURRENT` back.** An API 200 alone would miss a staging
  label that did not move, and the point of a rotation is that the new value is
  the one consumers get. Nothing is reported as rotated until that read matches

### Rollback is already there

`PutSecretValue` moves `AWSCURRENT` to the new version and demotes the previous
one to `AWSPREVIOUS`. No backup step of your own is needed:

```sh
aws secretsmanager get-secret-value --secret-id <arn> --version-stage AWSPREVIOUS
```

### Reading a failure

Britive keeps roughly the **first 250 characters** of the captured output, and
CloudWatch holds nothing more — so a script that logs its progress first has its
actual error truncated away. Both scripts buffer INFO and print the **reason
first**:

```
ERROR cannot describe secret 'app/db' in us-west-2: AccessDeniedException ...
trace: rotating secret 'app/db' in us-west-2, mode auto;
```

`ROTATE_VERBOSE=true` restores immediate progress logging for a hand-run.

### IAM

```json
{
  "Effect": "Allow",
  "Action": [
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetSecretValue",
    "secretsmanager:PutSecretValue"
  ],
  "Resource": "<your-secret-arn>"
}
```

Plus `kms:Decrypt` and `kms:GenerateDataKey` if the secret uses a customer-managed key.

### Prerequisites

`aws`, `jq`, and `python3` on the broker host — all three ship in the
`britive/bridge` image.
