# AWS Secrets Manager Scan

Enumerates the secrets in **one AWS account and region** and writes the Britive
Resource Manager scan payload. Each secret becomes an identity, so a rotation can
later target it the same way it targets any other discovered account.

### Script: `secretsmanager-scan.sh`

Runs on the Britive broker. Calls `ListSecrets` (paginated), classifies each
secret, and writes JSON to the broker-supplied path. **Read only** — it never
calls `GetSecretValue`.

#### Resource Attributes

A scan runs against a resource, and the broker injects that resource's attributes
upper-cased with a `RESOURCE_` prefix.

| Attribute | Arrives as | Required | Description |
|---|---|---|---|
| `AWS_REGION` | `RESOURCE_AWS_REGION` | Yes | Region to enumerate |
| `SECRET_PREFIX` | `RESOURCE_SECRET_PREFIX` | No | Name **prefix** filter |
| `SECRET_TAG_KEY` | `RESOURCE_SECRET_TAG_KEY` | No | Tag-key filter |
| `SECRET_TAG_VALUE` | `RESOURCE_SECRET_TAG_VALUE` | No | Tag-value filter |
| `GROUP_TAG_KEY` | `RESOURCE_GROUP_TAG_KEY` | No | Tag whose values become groups (default `Environment`) |

Setting the bare name directly overrides the attribute, so the script stays
runnable by hand for testing.

The filters exist to bound the blast radius. An unfiltered scan of a shared
account hands Resource Manager every secret in it, including other teams'.

#### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | — | Where to write the JSON. Injected by the broker. |
| `SECRET_ID_MAX_LENGTH` | No | `50` | Cap on identity/group ids. Minimum `20`. |

#### How It Works

1. Validates `BROKER_INJECTED_SCAN_OUTPUT_PATH` (fails immediately if unset).
2. Resolves the account id with `sts:GetCallerIdentity`.
3. Pages through `ListSecrets` in the target region, applying the prefix and tag filters.
4. Emits one identity per secret and one group per distinct `GROUP_TAG_KEY` value, plus the synthetic groups below.
5. Writes the payload; on failure writes a minimal valid JSON carrying the error so the broker can report it.

#### Identity Resolution

- **Identity `id`** is the secret **name**, not the ARN — the platform's
  `native_id` column is too short for an ARN, and the name is unique within one
  account and region, which is the scope of one resource.
- A name longer than `SECRET_ID_MAX_LENGTH` becomes `prefix-<8 hex of sha256>`
  rather than being truncated. Plain truncation would collapse
  `prod/db/app-primary` and `prod/db/app-replica` onto one id and silently merge
  two different secrets; the hash keeps them distinct. The full name stays in the
  `secret_name` attribute, and the count of shortened ids is reported in
  `scan_details`.
- **The full ARN** rides in the `secret_arn` attribute. That is what a rotation targets.
- Every identity carries a synthesized `email`, `first_name` and `last_name`.
  These are NOT NULL columns in the platform's account table, and an import
  otherwise fails with `Column 'email' cannot be null` after an apparently
  successful scan. The email local part combines the sanitized secret name with
  the ARN's trailing uniquifier, so `prod/db/app` and a literally-named
  `prod-db-app` cannot collide; the whole address is budgeted at 64 characters.

#### Groups Produced

| Group | Meaning |
|---|---|
| one per distinct `GROUP_TAG_KEY` value | e.g. `Environment=prod` |
| `rotation-enabled` / `rotation-disabled` | Whether AWS-native rotation is on |
| `service-owned` | Created by RDS, Redshift, etc. |

**Do not rotate `service-owned` secrets through Britive.** The owning service
holds its own copy of the credential and writing here desynchronises it. Both
rotation scripts refuse them unless `ALLOW_SERVICE_OWNED=true`.

#### Output Schema

- **`data.identities`** — one per secret, with attributes `secret_arn`,
  `secret_name`, `region`, `account_id`, `kms_key_id`, `rotation_enabled`,
  `owning_service`, and tags.
- **`data.groups`** — tag-derived and synthetic groups, members listed by identity `id`.
- **`data.permissions`** — empty. Resource policies would be one
  `GetResourcePolicy` call per secret, most secrets have none, and Resource
  Manager consumes groups rather than IAM documents. Tags ride along on
  `ListSecrets` for free, which is why grouping uses them.
- **`data.permission_mapping`** — empty; membership lives in `groups.members`.
- **`metadata`** — `resource_id` = `<account-id>:<region>`, `resource_type` =
  `AWSSecretsManager`, `scan_time`, `scan_details`, `scan_errors`,
  `attribute_resolution`.

#### IAM

```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:ListSecrets", "sts:GetCallerIdentity"],
  "Resource": "*"
}
```

`ListSecrets` cannot be scoped to individual secrets — the API does not support
it. Use the prefix and tag filters to control what the scan reports.

#### Prerequisites

`aws`, `jq`, and `python3` on the broker host. All three ship in the
`britive/bridge` image.
