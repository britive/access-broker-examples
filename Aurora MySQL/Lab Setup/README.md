# Aurora MySQL Lab Setup

CloudFormation template that stands up a self-contained lab for exercising the
Britive access broker against MySQL RDS.

## What It Builds

| Resource | Detail |
| --- | --- |
| **VPC** | `10.0.0.0/16`, Internet Gateway, two public subnets across two AZs |
| **MySQL RDS instance** | Engine `mysql` 8.0, `db.t3.micro`, 20 GiB gp3, not publicly accessible |
| **DB parameter group** | `default_authentication_plugin = mysql_native_password` for client/script compatibility |
| **Britive admin secret** | Secrets Manager `${ProjectName}/mysql/admin` — the RDS master user; broker reads this |
| **Breakglass secret** | Secrets Manager `${ProjectName}/mysql/breakglass` — emergency creds; broker does **not** read this |
| **Broker EC2 host** | Amazon Linux 2023, `t3.medium` (2 vCPU / 4 GiB RAM), 20 GiB gp3 |
| **IAM role** | EC2 gets `GetSecretValue`/`DescribeSecret` on the **admin secret only** + SSM core |

### Network Topology (simple)

Single VPC, broker in a public subnet with a public IP. The broker security
group allows **all outbound `443`** (to the Britive control plane, AWS APIs, and
OS package repos) rather than allow-listing individual Britive URLs, and `3306`
to the RDS security group. RDS accepts `3306` only from the broker SG. No NAT
gateway, no VPC endpoints — cheapest topology for a lab.

```
                Internet
                   │ :443 out
            ┌──────┴───────┐
            │  Broker EC2  │  (public subnet, public IP)
            │  britive     │
            │  broker      │
            └──────┬───────┘
                   │ :3306
            ┌──────┴───────┐
            │  MySQL RDS   │  (private, SG-restricted)
            └──────────────┘
```

## Prerequisites

- AWS CLI configured with credentials that can create VPC, EC2, RDS, IAM, and
  Secrets Manager resources.
- Permission to create a **named IAM role** (`--capabilities CAPABILITY_NAMED_IAM`).
- A Britive tenant with an **Access Broker pool** to register the EC2 broker
  against (download link + pool auth token from the console — see step 2).

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `ProjectName` | `britive-mysql-lab` | Name prefix for all resources, secrets, and tags |
| `DBName` | `systemdb` | Initial database; matches `GRANT ALL ON systemdb.*` in the temp-user script |
| `DBEngineVersion` | `8.0.40` | MySQL version (must be `8.0.x` to match the parameter group family) |
| `DBInstanceClass` | `db.t3.micro` | RDS class (free-tier eligible) |
| `DBAllocatedStorage` | `20` | RDS storage (GiB, min 20) |
| `BrokerInstanceType` | `t3.medium` | EC2 broker size (2 vCPU / 4 GiB RAM) |
| `BrokerRootVolumeSize` | `20` | EC2 root volume (GiB) |
| `LatestAmiId` | AL2023 SSM param | Amazon Linux 2023 AMI (auto-resolved) |
| `SSHKeyName` | `""` | Optional EC2 key pair; blank = SSM-only, no SSH |
| `SSHLocation` | `127.0.0.1/32` | CIDR allowed to SSH (only if `SSHKeyName` set) |

## Deploy

```bash
aws cloudformation deploy \
  --stack-name britive-mysql-lab \
  --template-file mysql-broker-lab.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

Override parameters with `--parameter-overrides Key=Value ...`.
By default there is **no SSH ingress** — connect to the broker via SSM Session
Manager. Set `SSHKeyName` + `SSHLocation=<your-ip>/32` to enable SSH.

RDS creation takes ~10-15 minutes; the stack completes when the instance is available.

> Region note: the template defaults to `us-west-2`, which matches the hardcoded
> region in the `temp-user/` and `temp_ro/` checkout/checkin scripts. Deploy in a
> different region only if you also update those scripts.

## After Deploy

### 1. Read the stack outputs

```bash
aws cloudformation describe-stacks --stack-name britive-mysql-lab \
  --query 'Stacks[0].Outputs' --output table
```

Use `MySQLEndpoint` as `dburl` and `BritiveAdminSecretArn` (or the secret name)
as `secret` when configuring the Britive permission env vars.

### 2. Finish the Britive broker install

Connect to the broker host and complete the install (the AMI bootstrap already
installed `jq`, the MySQL/MariaDB client, and Java):

```bash
aws ssm start-session --target <BrokerInstanceId>
```

Then follow the commented steps in the template's `UserData` — download the
broker package from **Admin → Access Broker → Broker Pools → Download Broker**,
set the pool auth token + tenant URL in `broker-config.yml`, and start the
`britive-broker` service. See also [`Linux/broker-install/redhat/`](../../Linux/broker-install/redhat/).

### 3. Create the breakglass DB user (one-time, out-of-band)

The broker EC2 role can read only the admin secret, so it cannot create the
breakglass user. Do this from an operator workstation with access to both
secrets:

```bash
ADMIN=$(aws secretsmanager get-secret-value --secret-id britive-mysql-lab/mysql/admin \
  --query SecretString --output text)
BG=$(aws secretsmanager get-secret-value --secret-id britive-mysql-lab/mysql/breakglass \
  --query SecretString --output text)

MYSQL_PWD=$(echo "$ADMIN" | jq -r .password) \
mysql -h <MySQLEndpoint> -u "$(echo "$ADMIN" | jq -r .username)" -e "
  CREATE USER '$(echo "$BG" | jq -r .username)'@'%' IDENTIFIED BY '$(echo "$BG" | jq -r .password)';
  GRANT ALL PRIVILEGES ON *.* TO '$(echo "$BG" | jq -r .username)'@'%' WITH GRANT OPTION;
  FLUSH PRIVILEGES;"
```

Notes:
- Run this from a workstation whose AWS identity can read **both** secrets — the
  broker EC2 role deliberately cannot read the breakglass secret.
- It also needs network reachability to the private RDS instance. Easiest path:
  temporarily add your workstation IP (`<your-ip>/32`, port 3306) to the DB
  security group, run the command, then remove the rule.

## How the Broker Uses This

The broker runs the checkout/checkin scripts under
[`../permissions/temp_ro/`](../permissions/temp_ro/) and
[`../permissions/temp-user/`](../permissions/temp-user/). Each script reads the
Britive admin secret from Secrets Manager to connect as master and provision or
remove a temporary MySQL user. Britive injects `user`, `host`, `dburl`, and
`secret` env vars per checkout.

## Cleanup

```bash
aws cloudformation delete-stack --stack-name britive-mysql-lab
```

The RDS instance uses `DeletionPolicy: Delete` (no final snapshot) so the stack
tears down cleanly. The breakglass DB user created in step 3 lives inside the
database and is removed with it.

## Cost Note

`db.t3.micro` is free-tier eligible; the Amazon Linux AMI is free. `t3.medium`
(chosen for the 4 GiB RAM requirement) is **not** free-tier — downsize to
`t3.micro`/`t3.small` if the broker fits in less RAM for your test.
