# Aurora MySQL Role Member Scripts

This directory contains scripts for managing temporary user roles in Aurora MySQL databases through AWS Secrets Manager integration.

## Files

- `checkout_sql_role.sh` - Creates a temporary MySQL user and grants specified role permissions
- `checkin_sql_role.sh` - Revokes role permissions from a user (cleanup script)

## Prerequisites

- AWS CLI configured with appropriate permissions
- `jq` command-line JSON processor
- MySQL client installed
- Access to AWS Secrets Manager (default region: `us-west-2`, override with `AWS_REGION`)

## Environment Variables

These variables are configured on the Britive permission and injected automatically during checkout/checkin. All variables are required.

| Variable | Description | Example |
| --- | --- | --- |
| `user` | Username (sanitized: domain and special chars stripped) | `john.doe@company.com` |
| `host` | MySQL host pattern for user authentication scope | `%` or `10.0.%` |
| `dburl` | MySQL database endpoint URL | `aurora-cluster.cluster-xyz.us-west-2.rds.amazonaws.com` |
| `secret` | AWS Secrets Manager secret ID for admin credentials | `prod/aurora/admin` |
| `database_name` | Target database name for permission scope | `appdb` |
| `table` | Table name (or `*` for all tables in the database) | `orders` |
| `role` | MySQL privilege(s) to grant | `SELECT` or `SELECT, INSERT` |

## Usage

### Example Checkout (Create User and Grant Role)

```bash
export user="temp_user"
export host="%.example.com"
export dburl="aurora-mysql-cluster.cluster-xxxxx.us-west-2.rds.amazonaws.com"
export secret="aurora-mysql-admin-credentials"
export database_name="appdb"
export table="orders"
export role="SELECT"

./checkout_sql_role.sh
```

This script will:

1. Generate a random password for the temporary user
2. Retrieve database admin credentials from AWS Secrets Manager
3. Create a MySQL user with the generated password
4. Grant the specified privilege(s) on `database_name.table` to the user
5. Output the username, password, and connection command

### Example Checkin (Revoke Permissions)

```bash
# Use the same environment variables as checkout
./checkin_sql_role.sh
```

This script will:

1. Retrieve database admin credentials from AWS Secrets Manager
2. Revoke the specified privilege(s) from the user on the database table
3. Clean up temporary configuration files

> **Note:** The checkin script only revokes permissions — it does not drop the user account. This is intentional for audit trail purposes.

## Security Features

- Temporary configuration files are automatically cleaned up on both success and failure
- Database admin credentials are retrieved securely from AWS Secrets Manager
- Random passwords are generated for each temporary user
- Username sanitization strips email domains and non-alphanumeric characters

## Error Handling

Both scripts validate all required environment variables before executing. They exit with status code `1` if any operation fails, and always clean up temporary credential files even on failure. The checkout script rolls back the created user if the subsequent `GRANT` fails.
