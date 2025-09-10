# MySQL Database Access Management Scripts

This repository contains scripts for managing temporary user accounts in AWS RDS MySQL databases. The scripts provide a secure way to grant and revoke database access using AWS Secrets Manager for credential management.

## Overview

The solution consists of two main scripts:
- `checkout.sh` - Creates temporary MySQL users with database access
- `checkin.sh` - Removes temporary MySQL users and cleans up access

## Files

### checkout.sh
Creates a new temporary MySQL user with:
- Randomly generated 16-character password
- Full privileges on the `systemdb` database
- User credentials retrieved from AWS Secrets Manager

### checkin.sh
Removes the temporary MySQL user and cleans up access permissions.

## Prerequisites

### System Requirements
- Bash shell environment
- MySQL client tools (`mysql` command)
- AWS CLI configured with appropriate permissions
- `jq` command-line JSON processor
- `/dev/urandom` available for password generation

### AWS Resources Required
- AWS RDS MySQL database instance
- AWS Secrets Manager secret containing master database credentials
- IAM role/user with appropriate permissions (see Permissions section)

## Usage

### Environment Variables

Both scripts require the following environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `user` | Base username (will be sanitized) | `john.doe@company.com` |
| `host` | MySQL host pattern for user creation | `%` or `10.0.%` |
| `dburl` | MySQL database endpoint URL | `mydb.cluster-xyz.us-west-2.rds.amazonaws.com` |
| `secret` | AWS Secrets Manager secret ID | `prod/mysql/master` |

### Checkout (Create User)

```bash
export user="john.doe@company.com"
export host="%"
export dburl="mydb.cluster-xyz.us-west-2.rds.amazonaws.com"
export secret="prod/mysql/master"

./checkout.sh
```

**Output:**
```
johndoe
Ax7KmP9qR2nV8sL1
mysql -hmydb.cluster-xyz.us-west-2.rds.amazonaws.com -ujohndoe -p"Ax7KmP9qR2nV8sL1"
```

### Checkin (Remove User)

```bash
export user="john.doe@company.com"
export host="%"
export dburl="mydb.cluster-xyz.us-west-2.rds.amazonaws.com"
export secret="prod/mysql/master"

./checkin.sh
```

## Security Features

### Username Sanitization
- Removes email domain (`user@domain.com` → `user`)
- Strips non-alphanumeric characters for MySQL compatibility
- Prevents SQL injection through username manipulation

### Password Generation
- 16-character random passwords using `/dev/urandom`
- Alphanumeric characters only (A-Z, a-z, 0-9)
- No special characters to avoid shell escaping issues

### Credential Security
- Master database credentials stored in AWS Secrets Manager
- Temporary MySQL configuration files with restrictive permissions
- Automatic cleanup of temporary credential files
- No credentials stored in environment variables or command history

### Temporary File Handling
- Random 13-character temporary filenames
- Files automatically removed after use
- Configuration files contain sensitive data only temporarily

## Database Permissions

The temporary users are granted:
```sql
GRANT ALL ON systemdb.* TO 'username'@'host';
```

This provides full access to the `systemdb` database only, including:
- SELECT, INSERT, UPDATE, DELETE
- CREATE, DROP, ALTER (tables, indexes, etc.)
- EXECUTE (stored procedures)
- All other standard database operations on `systemdb`

## AWS Secrets Manager Format

The AWS Secrets Manager secret must contain JSON with the following structure:

```json
{
  "username": "admin",
  "password": "your-master-password"
}
```

## Error Handling

Both scripts implement proper error handling:
- Exit code 0 on success
- Exit code 1 on failure
- Automatic cleanup on errors
- MySQL connection failures are caught and reported

## Troubleshooting

### Common Issues

**MySQL Connection Failures:**
- Verify database endpoint URL
- Check security groups allow connections
- Confirm master credentials in Secrets Manager

**Permission Errors:**
- Ensure AWS CLI is configured correctly
- Verify IAM permissions (see Permissions section)
- Check MySQL master user has USER creation privileges

**Script Execution Errors:**
- Verify all required tools are installed (`mysql`, `aws`, `jq`)
- Check environment variables are set correctly
- Ensure scripts have execute permissions (`chmod +x *.sh`)

### Debug Mode

Add debug output by modifying scripts:
```bash
set -x  # Add at top of script for verbose output
```

## Limitations

- Users are created with `ALL` privileges on `systemdb` database only
- Host pattern must be specified (not automatically detected)
- Requires MySQL client tools on execution environment
- Limited to MySQL/MariaDB databases

## Best Practices

1. **Use specific host patterns** when possible instead of `%`
2. **Rotate Secrets Manager credentials** regularly
3. **Monitor database user creation/deletion** through CloudTrail
4. **Use least-privilege IAM policies** for the service account
5. **Set up alerts** for failed checkout/checkin operations
6. **Regular cleanup** of any orphaned database users

## Security Considerations

- Scripts should be run in secure environments only
- Consider using AWS Systems Manager Session Manager for remote execution
- Implement audit logging for user creation/deletion events
- Regular review of active database users
- Consider implementing time-based user expiration

## Integration Examples

### With CI/CD Pipeline
```yaml
steps:
  - name: Checkout DB Access
    run: |
      export user="${{ github.actor }}"
      export host="%"
      export dburl="${{ secrets.DB_URL }}"
      export secret="${{ secrets.DB_SECRET }}"
      ./checkout.sh
```

### With Monitoring
```bash
# Add to checkout.sh for monitoring
aws cloudwatch put-metric-data \
  --namespace "Database/Access" \
  --metric-data MetricName=UserCheckout,Value=1,Unit=Count
```