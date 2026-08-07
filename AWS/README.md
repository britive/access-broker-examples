# AWS

Broker scripts for AWS services that Britive manages directly, as opposed to the
AWS *destination* scripts under
[Secret synchronization](../Secret%20synchronization/), which push a
Britive-held value outward.

| Folder | What |
|---|---|
| [`secrets-manager/`](secrets-manager/) | Scan and rotate secrets held in AWS Secrets Manager |

## Which AWS folder do I want?

The repo has three places that touch AWS secrets, and they do different jobs:

| Goal | Use |
|---|---|
| Britive holds the value; copy it into Secrets Manager on checkout | [`Secret synchronization/aws/`](../Secret%20synchronization/aws/) |
| Secrets Manager holds the value; have Britive replace it on a schedule | [`secrets-manager/rotate/`](secrets-manager/rotate/) |
| An **Active Directory** account is the real credential, and a secret mirrors it | [`Active Directory/rotate/rotate-ad-account-aws-secret.sh`](../Active%20Directory/rotate/rotate-ad-account-aws-secret.sh) |

Synchronization copies a value Britive already owns. Rotation changes the value
at its source and records the new one. They are not interchangeable: syncing a
stale value overwrites a good one, and rotating a secret whose real owner is a
directory account leaves the secret advertising a password nothing accepts.

## Credentials

Every script here uses the standard AWS credential chain — instance profile, ECS
task role, IRSA, or environment variables. None of them take an access key as a
parameter. Scope the broker's role to the specific secrets it manages; the
per-script READMEs list the exact IAM actions.
