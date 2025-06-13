#!/bin/bash

# === Configuration ===
CASSANDRA_HOST="localhost"
CASSANDRA_PORT="9042"
CASSANDRA_ADMIN_USER="cassandra"
CASSANDRA_ADMIN_PASS="your_admin_password"

# === Input parameter ===
TARGET_USER="$1"

# === Usage ===
if [ -z "$TARGET_USER" ]; then
  echo "Usage: $0 <target_user>"
  exit 1
fi

# === Drop user ===
cat <<EOF | cqlsh $CASSANDRA_HOST $CASSANDRA_PORT -u $CASSANDRA_ADMIN_USER -p $CASSANDRA_ADMIN_PASS
DROP ROLE $TARGET_USER;
EOF

echo "User $TARGET_USER dropped."

