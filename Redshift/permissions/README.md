# AWS Redshift User Management Scripts

This repository contains two Bash scripts for managing user accounts in AWS Redshift. The scripts allow you to create an admin user (if they don't already exist) and remove a user from the database.

## Prerequisites

- Make sure you have `psql` installed, which is required to execute SQL commands against AWS Redshift.
- Ensure `openssl` is installed to generate strong passwords for the new user.
- These scripts assume you have the necessary permissions to create and drop users in AWS Redshift.

## Scripts

### 1. `Redshift/permissions/redshift-admin-checkout.sh`

This script creates an admin user in AWS Redshift with superuser privileges if the user doesn't already exist. It generates a strong random password and outputs the login command with the password for the new user.

#### Usage

1. Open the script and configure the following variables:
   - `REDSHIFT_HOST`: The endpoint of your Redshift cluster.
   - `REDSHIFT_PORT`: The port number for Redshift, typically `5439`.
   - `REDSHIFT_DB`: The name of the Redshift database.
   - `REDSHIFT_ADMIN`: An admin username with permission to create users.
   - `REDSHIFT_ADMIN_PASS`: The password for the Redshift admin user.
   - `USER`: The user ID for the new user to be created.

2. Make sure the right values are passed to the scripts upon checkout and checkin. ResourceTypes configurations can contain the the DB information and related metadata for each Resource.
