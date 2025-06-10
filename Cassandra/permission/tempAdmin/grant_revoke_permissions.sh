#!/bin/bash

# === Configuration ===
CASSANDRA_HOST="localhost"
CASSANDRA_PORT="9042"
CASSANDRA_ADMIN_USER="cassandra"
CASSANDRA_ADMIN_PASS="your_admin_password"

# === Input parameters ===
ACTION="$1"         # grant or revoke
TARGET_USER="$2"    # user to grant/revoke
PERMISSIONS="$3"    # comma-separated list e.g. SELECT,MODIFY
SCOPE_TYPE="$4"     # KEYSPACE or TABLE
KEYSPACE="$5"       # keyspace name
TABLE="$6"          # table name (if TABLE scope)

# === Usage ===
if [ -z "$ACTION" ] || [ -z "$TARGET_USER" ] || [ -z "$PERMISSIONS" ] || [ -z "$SCOPE_TYPE" ] || [ -z "$KEYSPACE" ]; then
  echo "Usage: $0 <grant|revoke> <target_user> <permissions> <KEYSPACE|TABLE> <keyspace> [table]"
  echo "Example: $0 grant myuser SELECT,MODIFY TABLE mykeyspace mytable"
  exit 1
fi

# === Prepare the CQL ===
IFS=',' read -ra PERM_ARRAY <<< "$PERMISSIONS"

CQL=""
for PERM in "${PERM_ARRAY[@]}"; do
  PERM_TRIMMED="$(echo "$PERM" | xargs)"
  if [ "$SCOPE_TYPE" == "KEYSPACE" ]; then
    CQL+="\n${ACTION^^} $PERM_TRIMMED ON KEYSPACE $KEYSPACE TO $TARGET_USER;"
  elif [ "$SCOPE_TYPE" == "TABLE" ]; then
    if [ -z "$TABLE" ]; then
      echo "ERROR: TABLE scope requires table name."
      exit 1
    fi
    CQL+="\n${ACTION^^} $PERM_TRIMMED ON TABLE $KEYSPACE.$TABLE TO $TARGET_USER;"
  else
    echo "ERROR: Unknown SCOPE_TYPE $SCOPE_TYPE (must be KEYSPACE or TABLE)."
    exit 1
  fi
done

# === Execute CQL ===
echo -e "Executing:\n$CQL\n"

echo -e "$CQL" | cqlsh $CASSANDRA_HOST $CASSANDRA_PORT -u $CASSANDRA_ADMIN_USER -p $CASSANDRA_ADMIN_PASS

echo "Done."

