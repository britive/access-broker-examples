#!/bin/bash

# === Configuration ===
CASSANDRA_HOST="localhost"
CASSANDRA_PORT="9042"
CASSANDRA_ADMIN_USER="cassandra"
CASSANDRA_ADMIN_PASS="your_admin_password"

# === Input parameters ===
NEW_USER="$1"
NEW_PASS="$2"

# === Usage ===
if [ -z "$NEW_USER" ] || [ -z "$NEW_PASS" ]; then
  echo "Usage: $0 <new_user> <new_password>"
  exit 1
fi

# === Create user ===
cat <<EOF | cqlsh $CASSANDRA_HOST $CASSANDRA_PORT -u $CASSANDRA_ADMIN_USER -p $CASSANDRA_ADMIN_PASS
CREATE ROLE $NEW_USER WITH PASSWORD = '$NEW_PASS' AND LOGIN = true;
EOF

echo "User $NEW_USER created."

