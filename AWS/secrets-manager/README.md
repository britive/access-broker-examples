# AWS Secrets Manager

Scan and rotation scripts for secrets held in AWS Secrets Manager, run by the
Britive Access Broker.

```
secrets-manager/
├── scans/
│   └── secretsmanager-scan.sh      inventory the secrets in one account + region
└── rotate/
    ├── rotate-secret-value.sh      the secret IS the system of record
    └── rotate-secret-with-target.sh  an account is; change it first, secret second
```

There is no `permissions/` folder here: these scripts serve scans and scheduled
rotations, not a checkout/checkin flow.

## The model

| Resource Manager concept | What it is here |
|---|---|
| resource | one AWS **account + region** scope |
| identity ("account") | one **secret**, keyed by its **name** |
| group | one distinct value of a chosen tag, plus three synthetic ones |

That is the shape Resource Manager already has — a scan discovers accounts on a
resource, a rotation rotates a discovered account — so a secret maps onto an
account without bending anything.

**The id is the secret name, not the ARN.** The platform stores it in a short
`native_id` column that a full ARN overflows:

```
could not execute statement [Data truncation: Data too long for column 'native_id' at row 1]
```

The name is the right key regardless: it is unique within one AWS account and
region, which is exactly the scope of one resource. The full ARN rides in the
`secret_arn` attribute — attributes go into a JSON column, so length is not a
constraint there — and that is what a rotation targets.

## Secret values are never inventoried

The scan calls `ListSecrets` and nothing else. No `GetSecretValue`, no value in
the payload, none in the logs.

The scan payload is uploaded to and stored by the Britive platform, and echoed
into the broker log whenever validation fails. A value placed in it is exposed in
both. What the scan records is the *coordinates* — ARN, name, region, account,
KMS key, rotation state, tags — and a rotation reads the value at rotation time
under that ARN. Britive gains control of the value by rotating it, not by
inventorying it.

## Britive supplies the new password

Both rotation scripts require `AWS_NEW_PASSWORD` and neither can generate one.

That is not a limitation to work around. A password generated inside the script
would exist only in that process: the platform could neither store it nor vend it
afterwards, so the rotated credential would be lost the moment the script
exited — the secret's consumers would be locked out with nobody holding the new
value. Configure the attribute on the rotation in the Britive console and the
value arrives encrypted, which is also why it never appears in the broker's
request log.

## Service-owned secrets

A secret created by RDS, Redshift, or another AWS service is rotated by that
service, which holds its own copy of the credential. Writing a value here
desynchronises the two. Both rotation scripts refuse such a secret unless
`ALLOW_SERVICE_OWNED=true`, and the scan puts them in a `service-owned` group so
they are easy to exclude from a profile.

## Documentation

- [`scans/README.md`](scans/README.md) — attributes, groups, id shortening, IAM
- [`rotate/README.md`](rotate/README.md) — which script, the target hook, ordering, rollback

## Verify

```sh
bash -n scans/*.sh rotate/*.sh
shellcheck -S style scans/*.sh rotate/*.sh
```
