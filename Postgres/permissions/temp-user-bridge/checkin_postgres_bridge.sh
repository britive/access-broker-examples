#!/bin/bash
#
# Britive checkin script: RDS PostgreSQL JIT role removal + Bridge session teardown
#
# Drops the temporary PostgreSQL role created at checkout and deletes the Bridge
# checkout, which immediately terminates any active proxied session.
#
# Required env vars (set by Britive Resource Type / Profile):
#   user    - requesting user's email (Britive auto-populates)
#   dburl   - RDS / Aurora PostgreSQL endpoint hostname
#   secret  - AWS Secrets Manager secret ID holding admin {username, password}
#   TRX     - Britive transaction ID (matches the checkout TRX)
#
# Optional env vars (with defaults):
#   DB_NAME     - Database the checkout granted on (default: postgres). MUST match
#                 the checkout: DROP OWNED BY only clears objects in the database
#                 it runs in, and a leftover object elsewhere blocks DROP ROLE.
#   DB_PORT     - PostgreSQL port on the target (default: 5432)
#   DB_CA_CERT  - path to the RDS CA bundle on the broker; enables server cert
#                 verification (see checkout script header for details)
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   BROKER_API  - Path to broker-bridge-api.sh (default: /opt/britive-broker/scripts/broker-bridge-api.sh)
#
# Why this is more than one DROP statement, unlike the MySQL flow: PostgreSQL
# refuses to drop a role that still owns objects or holds privileges anywhere in
# the cluster ("role cannot be dropped because some objects depend on it").
# REASSIGN OWNED hands anything the role created to the admin so the work is not
# destroyed, DROP OWNED then clears the remaining privilege grants, and only then
# is DROP ROLE accepted.

set -u

# Sanitize a PostgreSQL role name from the email local part -- must match the
# checkout logic exactly, or checkin drops nothing and the role outlives the
# session.
PG_USER="${user%%@*}"
PG_USER="${PG_USER//[^a-zA-Z0-9_]/}"
PG_USER="$(printf '%s' "$PG_USER" | tr '[:upper:]' '[:lower:]')"

PG_URL="${dburl}"
SECRET="${secret}"
TRANSACTION_ID="${TRX}"
DB_NAME="${DB_NAME:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_CA_CERT="${DB_CA_CERT:-}"
AWS_REGION="${AWS_REGION:-us-west-2}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

pgpass=$(mktemp --suffix=.pgpass) || exit 1
chmod 600 "$pgpass"
trap 'rm -f "$pgpass"' EXIT

finish () {
  exit "$1"
}

rc=0

secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text) || finish 1

db_admin_user=$(echo "$secret_value" | jq -r '.username')
db_admin_password=$(echo "$secret_value" | jq -r '.password')

printf '%s:%s:*:%s:%s\n' "$PG_URL" "$DB_PORT" "$db_admin_user" "$db_admin_password" > "$pgpass"

# TLS to the target: verify the chain and hostname with DB_CA_CERT when provided,
# otherwise encrypt without verification.
if [ -n "$DB_CA_CERT" ]; then
  PGSSLMODE=verify-full
  PGSSLROOTCERT="$DB_CA_CERT"
  export PGSSLROOTCERT
else
  PGSSLMODE=require
fi
export PGPASSFILE="$pgpass" PGSSLMODE
export PGCONNECT_TIMEOUT=15

psql_admin() {
  psql --no-psqlrc --quiet --no-align --tuples-only \
    -v ON_ERROR_STOP=1 \
    -h "$PG_URL" -p "$DB_PORT" -U "$db_admin_user" -d "$DB_NAME" \
    -c "$1"
}

# Nothing to drop is a normal outcome (checkout may have failed before creating
# the role), so absence is not an error -- but a role that IS present and cannot
# be dropped must fail the checkin loudly, since it would otherwise keep its
# access.
role_exists=$(psql_admin "SELECT 1 FROM pg_roles WHERE rolname = '${PG_USER}';" 2>/dev/null | tr -d '[:space:]')

if [ "$role_exists" = "1" ]; then
  # Terminate the role's own backends first. An open session would keep working
  # against the target until it disconnected, and it also blocks nothing else --
  # but leaving it alive defeats the point of revoking access now.
  psql_admin "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
     WHERE usename = '${PG_USER}' AND pid <> pg_backend_pid();" >/dev/null 2>&1

  psql_admin "
    REASSIGN OWNED BY \"${PG_USER}\" TO \"${db_admin_user}\";
    DROP OWNED BY \"${PG_USER}\";
    DROP ROLE IF EXISTS \"${PG_USER}\";" >/dev/null || rc=1
fi

# Delete the Bridge checkout -- revokes the proxy credential and
# terminates any active session immediately
"${BROKER_API}" checkout-delete "${TRANSACTION_ID}" || rc=1

finish "$rc"
