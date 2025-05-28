# PostgreSQL DBA Access Scripts for AWS RDS

This package contains two shell scripts to manage DBA access to a PostgreSQL database hosted on Amazon RDS. Credentials are securely retrieved from AWS Secrets Manager.

## Requirements

- AWS CLI
- `jq`
- `psql` (PostgreSQL client)
- `openssl`

## Setup

1. Store your RDS DB credentials in AWS Secrets Manager in the following JSON format:

  ```json
  {
    "host": "your-db-host.rds.amazonaws.com",
    "port": 5432,
    "username": "your-master-user",
    "password": "your-password"
  }
  ```

2. Set the required environment variables:

  ```bash
  export SECRET_NAME="your-secret-name"
  export DB_NAME="your-db-name"
  export USER_EMAIL="user@example.com"
  ```

3. (optionally) Create AWS Resources

  ```bash
  aws cloudformation deploy \
    --template-file aws_sample_db.yaml \
    --stack-name postgres-rds-stack \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides DBPassword=YourSecurePassword VpcId=vpc-xxxx SubnetIds='["subnet-aaa","subnet-bbb"]'
  ```

## Usage

### Grant Access

```bash
./grant_dba_access.sh
```

Outputs a temporary password and grants DBA privileges.

### Revoke Access

```bash
./revoke_dba_access.sh
```

Revokes privileges and deletes the database user.

## Security

- Uses `openssl` to generate a secure password.
- Avoids storing credentials in the script.
- Can be integrated with automation pipelines.
