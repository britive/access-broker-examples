# Aurora MySQL Role Member Scripts

This directory contains scripts for managing temporary user roles in Aurora MySQL databases through AWS Secrets Manager integration.

## Files

- `checkout_sql_role.sh` - Creates a temporary MySQL user and grants specified role permissions
- `checkin_sql_role.sh` - Revokes role permissions from a user (cleanup script)

## Prerequisites

- AWS CLI configured with appropriate permissions
- `jq` command-line JSON processor
- MySQL client installed
- Access to AWS Secrets Manager in us-west-2 region

## Environment Variables

The env variables are set automatically by the platform and made available during checkout/in. The scripts expect the following environment variables:

- `user` - The MySQL username to create/manage
- `host` - The MySQL host for user authentication scope
- `dburl` - The MySQL database URL/endpoint
- `secret` - AWS Secrets Manager secret ID containing database credentials
- `table` - The table name for permission scope
- `role` - The MySQL role/privilege to grant (e.g., SELECT, INSERT, UPDATE, DELETE)

## Usage

### Example Checkout (Create User and Grant Role)

```bash
export user="temp_user"
export host="%.example.com"
export dburl="aurora-mysql-cluster.cluster-xxxxx.us-west-2.rds.amazonaws.com"
export secret="aurora-mysql-admin-credentials"
export table="users"
export role="SELECT"

./checkout_sql_role.sh
```

This script will:

1. Generate a random password for the temporary user
2. Retrieve database admin credentials from AWS Secrets Manager
3. Create a MySQL user with the generated password
4. Grant the specified role on the database table to the user
5. Output the username, password, and connection command

### Example Checkin (Revoke Permissions)

```bash
# Use the same environment variables as checkout
./checkin_sql_role.sh
```

This script will:

1. Retrieve database admin credentials from AWS Secrets Manager
2. Revoke the specified role from the user on the database table
3. Clean up temporary configuration files

## Security Features

- Temporary configuration files are automatically cleaned up
- Database credentials are retrieved securely from AWS Secrets Manager
- Random passwords are generated for temporary users
- Username sanitization removes special characters

## Configuration

Update the `DATABASE_NAME` variable in both scripts to match your target database:

```bash
DATABASE_NAME="your_database_name"
```

## Error Handling

Both scripts include error handling and will exit with status code 1 if any database operation fails. Temporary files are cleaned up even on failure.