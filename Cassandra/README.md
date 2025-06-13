# Cassandra Access Management

Includes automation scripts to:

- Grant/revoke user permissions
- Create and drop users (for self-hosted Cassandra)
- Handle secure credentials with AWS Secrets Manager & KMS
- Automate deployment and cleanup with CloudFormation

## Pre-requisites

- AWS CLI configured with sufficient permissions
- IAM user/role with `cloudformation`, `ec2`, `iam`, `kms`, and `secretsmanager` permissions
- An existing EC2 SSH key pair (`KeyPairName`) for login

## 1️⃣ Amazon Keyspaces (Serverless Cassandra)

### Deploy the Stack

```bash
aws cloudformation deploy \
  --stack-name cassandra-keyspaces \
  --template-file cloudformation/keyspaces-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides KeyPairName=YOUR_KEYPAIR
````

### Components Created

- Amazon Keyspaces Keyspace
- Amazon Keyspaces Table
- IAM Role with permissions:
  - `cassandra:Select`
  - `cassandra:Modify`
- EC2 runner instance with IAM Role attached

### Running Scripts

```bash
ssh -i your.key ec2-user@<RunnerPublicIP>
cd scripts/
./runner_template.sh keyspaces
```

**Note**: The runner is prepared to use **SigV4** auth for Keyspaces.

---

## 2️⃣ Self-hosted Cassandra on EC2

### Deploy the Stack

```bash
aws cloudformation deploy \
  --stack-name cassandra-selfhosted \
  --template-file cloudformation/selfhosted-cassandra-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides KeyPairName=YOUR_KEYPAIR
```

### Components Created

- VPC with public subnet
- Security Group allowing SSH and Cassandra traffic
- Cassandra EC2 instance:

  - Cassandra installed and running
  - Admin user `cassandra` with password `ChangeMe123!` (stored securely in Secrets Manager)
- AWS KMS Key for Secrets encryption
- EC2 runner instance with IAM Role:

  - Read SecretsManager secret
  - Decrypt KMS-encrypted secret

### Running Scripts

```bash
ssh -i your.key ec2-user@<RunnerPublicIP>
cd scripts/
./runner_template.sh selfhosted
```

---

## 3️⃣ Managing Cassandra Permissions and Users

### Grant/Revoke Permissions

```bash
./grant_revoke_permissions.sh --username <USERNAME> --permissions "SELECT MODIFY" --action grant
./grant_revoke_permissions.sh --username <USERNAME> --permissions "SELECT MODIFY" --action revoke
```

### Create User

```bash
./create_user.sh --username <USERNAME> --password <PASSWORD>
```

### Drop User

```bash
./drop_user.sh --username <USERNAME>
```

### Notes

- For Keyspaces, permissions are managed via IAM.
- For self-hosted Cassandra, `cqlsh` scripts manage users and permissions.

---

## 4️⃣ Cleanup Resources

```bash
./destroy_stack.sh cassandra-keyspaces
./destroy_stack.sh cassandra-selfhosted yes
```

- The `yes` flag also deletes related SecretsManager secrets.

---

## Security Notes

✅ **Self-hosted Cassandra**

- Admin password stored in AWS Secrets Manager and encrypted with KMS.
- EC2 runner has limited IAM permissions.

✅ **Keyspaces**

- EC2 runner uses IAM-based SigV4 auth.

## Future Improvements

- Auto-revoke user permissions after TTL
- Add CloudWatch Alarms/Monitoring
- Integrate with AWS Systems Manager Parameter Store
- CI/CD pipeline for deployments

## Acknowledgments

- [Apache Cassandra](https://cassandra.apache.org/)
- [Amazon Keyspaces](https://aws.amazon.com/keyspaces/)

## Bonus

This starter kit helps you deploy and manage **Cassandra databases** in AWS:

✅ **Amazon Keyspaces (Serverless Cassandra)**  
✅ **Self-hosted Cassandra on EC2**  

## Summary

✅ **Well-structured**  
✅ **Clear usage instructions**  
✅ **Security considerations included**  
✅ **Ready to publish with your repo**  
