#!/bin/bash

# Variables
REDSHIFT_HOST=$host
REDSHIFT_PORT=$port
REDSHIFT_DB=$db
REDSHIFT_ADMIN=$admin
REDSHIFT_ADMIN_PASS=$pass
USER=$user

# Generate a strong random password
NEW_PASSWORD=$(openssl rand -base64 12)

# Check if the user exists and create the user if they don't
psql "host=$REDSHIFT_HOST port=$REDSHIFT_PORT dbname=$REDSHIFT_DB user=$REDSHIFT_ADMIN password=$REDSHIFT_ADMIN_PASS" <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_user WHERE usename = '$USER') THEN
        -- Create the user with a strong random password
        EXECUTE format('CREATE USER %I PASSWORD %L', '$USER', '$NEW_PASSWORD');
        RAISE NOTICE 'User $USER created with a strong password: $NEW_PASSWORD';
        
        -- Grant superuser privileges
        EXECUTE format('ALTER USER %I WITH SUPERUSER', '$USER');
        RAISE NOTICE 'Superuser privileges granted to $USER.';
    ELSE
        RAISE NOTICE 'User $USER already exists. No action taken.';
    END IF;
END \$\$;
EOF

# Chechout output
echo "psql -h $REDSHIFT_HOST -p $REDSHIFT_PORT -d $REDSHIFT_DB -U $USER"
echo "Password: $NEW_PASSWORD"