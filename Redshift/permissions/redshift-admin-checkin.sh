#!/bin/bash

# Variables
REDSHIFT_HOST=$host
REDSHIFT_PORT=$port
REDSHIFT_DB=$db
REDSHIFT_ADMIN=$admin
REDSHIFT_ADMIN_PASS=$pass
USER=$user

# Check if the user exists and drop the user if they do
psql "host=$REDSHIFT_HOST port=$REDSHIFT_PORT dbname=$REDSHIFT_DB user=$REDSHIFT_ADMIN password=$REDSHIFT_ADMIN_PASS" <<EOF
DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_user WHERE usename = '$USER') THEN
        -- Revoke privileges from the user
        EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM %I', '$USER');
        EXECUTE format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM %I', '$REDSHIFT_DB', '$USER');
        
        -- Drop the user
        EXECUTE format('DROP USER %I', '$USER');
        RAISE NOTICE 'User $USER has been removed successfully.';
    ELSE
        RAISE NOTICE 'User $USER does not exist. No action taken.';
    END IF;
END \$\$;
EOF