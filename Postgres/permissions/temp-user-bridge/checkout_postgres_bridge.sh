#!/bin/bash
#
# Britive checkout script: RDS PostgreSQL JIT role + Bridge proxied session
#
# Creates a temporary PostgreSQL role with a random password, then registers a
# database checkout with the Britive Bridge using the caller's BRIDGE
# CREDENTIALS (native_auth=bridge_credentials). The real PostgreSQL credentials
# never leave the broker/Bridge.
#
# Bridge credential (provided by the broker as env vars):
#   BRIDGE_AUTH_PASSWORD - bridge password the user types at the native
#                          psql password prompt
#
# Identity: the native login username is the user's Britive identity (the email
# in `user`) -- the SAME value as the checkout owner. The Bridge matches BOTH
# the native username (before %) AND the browser SSO identity against the
# checkout's "username" field, so they must be identical. The profile "Bridge
# Username" field is NOT used for matching.
#
# Required env vars (set by Britive Resource Type / Profile):
#   user                 - requesting user's email (Britive auto-populates)
#   dburl                - RDS / Aurora PostgreSQL endpoint hostname
#   secret               - AWS Secrets Manager secret ID holding admin {username, password}
#   TRX                  - Britive transaction ID
#   BRIDGE_URL           - Bridge hostname; one NLB serves browser and native sessions
#   EXPIRATION           - Checkout duration in seconds
#   BRIDGE_AUTH_PASSWORD - bridge password (see above)
#
# Optional env vars (with defaults):
#   DB_NAME     - Database the grants apply to (default: postgres)
#   DB_PORT     - PostgreSQL port on the target (default: 5432)
#   NATIVE_PORT - Bridge native PostgreSQL listener port (default: 5432)
#   TARGET_TLS  - true/false, TLS from Bridge to the target (default: true)
#   DB_CA_CERT  - path to the RDS CA bundle on the broker; enables server cert
#                 verification for the admin connection (sslmode=verify-full).
#                 Without it the connection is encrypted but the chain is not
#                 verified (sslmode=require).
#                 Download: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   BROKER_API  - Path to broker-bridge-api.sh (default: /opt/britive-broker/scripts/broker-bridge-api.sh)
#
# Differences from the MySQL flow, both forced by PostgreSQL semantics:
#   * No `host` variable. A MySQL account is 'user'@'host'; a PostgreSQL role is
#     cluster-wide and host restrictions live in pg_hba.conf, so there is nothing
#     to pass.
#   * Grants are issued twice -- once at database level and once inside the
#     target database's `public` schema. From PG 15 the public schema no longer
#     grants CREATE to PUBLIC, so a database-level GRANT alone leaves the role
#     able to connect but unable to create anything.

set -u

# Sanitize a PostgreSQL role name from the email local part. Lowercased because
# an unquoted identifier folds to lower case in PostgreSQL: creating "JDoe" then
# referring to jdoe would otherwise miss. Underscores are kept (legal in an
# identifier, unlike MySQL's stricter set here) and the result is quoted in every
# statement below.
USER_EMAIL="${user}"
PG_USER="${USER_EMAIL%%@*}"
PG_USER="${PG_USER//[^a-zA-Z0-9_]/}"
PG_USER="$(printf '%s' "$PG_USER" | tr '[:upper:]' '[:lower:]')"

PG_URL="${dburl}"
SECRET="${secret}"
TRANSACTION_ID="${TRX}"
DB_NAME="${DB_NAME:-postgres}"
DB_PORT="${DB_PORT:-5432}"
NATIVE_PORT="${NATIVE_PORT:-5432}"
TARGET_TLS="${TARGET_TLS:-true}"
DB_CA_CERT="${DB_CA_CERT:-}"
AWS_REGION="${AWS_REGION:-us-west-2}"
BRIDGE_AUTH_PASSWORD="${BRIDGE_AUTH_PASSWORD:-}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

require_var() {
  var_name="$1"
  eval "var_value=\${$1:-}"
  if [ -z "$var_value" ]; then
    echo "error: required env var missing: $var_name" >&2
    exit 1
  fi
}

require_var user
require_var dburl
require_var secret
require_var TRX
require_var BRIDGE_URL
require_var EXPIRATION
require_var BRIDGE_AUTH_PASSWORD

[ -n "$PG_USER" ] || { echo "error: cannot derive a role name from '${USER_EMAIL}'" >&2; exit 1; }

# PostgreSQL truncates identifiers at 63 bytes (NAMEDATALEN-1) SILENTLY, which
# would make checkin drop a different name than checkout created.
if [ "${#PG_USER}" -gt 63 ]; then
  echo "error: derived role name '${PG_USER}' is ${#PG_USER} chars; PostgreSQL allows at most 63" >&2
  exit 1
fi

# Create temp files with restrictive perms BEFORE writing credentials
pgpass=$(mktemp --suffix=.pgpass) || exit 1
payload=$(mktemp --suffix=.json) || exit 1
chmod 600 "$pgpass" "$payload"
trap 'rm -f "$pgpass" "$payload"' EXIT

finish () {
  exit "$1"
}

# Random password for the temp role -- only the Bridge ever sees it.
# Alphanumeric only, so it needs no escaping inside the SQL string literal below.
db_user_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

# Fetch admin creds from Secrets Manager
secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text) || finish 1

db_admin_user=$(echo "$secret_value" | jq -r '.username')
db_admin_password=$(echo "$secret_value" | jq -r '.password')

# A password file rather than PGPASSWORD: the environment of a process is
# readable by anything running as the same uid in the container, and this one
# holds the RDS admin credential. Field order is host:port:database:user:password
# and a literal '*' matches any database.
printf '%s:%s:*:%s:%s\n' "$PG_URL" "$DB_PORT" "$db_admin_user" "$db_admin_password" > "$pgpass"

# TLS to the target. verify-full also checks the hostname, which is what makes
# the CA bundle worth supplying; without a bundle the session is still encrypted
# but an interceptor with any certificate would be accepted.
if [ -n "$DB_CA_CERT" ]; then
  PGSSLMODE=verify-full
  PGSSLROOTCERT="$DB_CA_CERT"
  export PGSSLROOTCERT
else
  PGSSLMODE=require
fi
export PGPASSFILE="$pgpass" PGSSLMODE
export PGCONNECT_TIMEOUT=15

# -v ON_ERROR_STOP=1 makes psql exit non-zero on the first failed statement.
# Without it psql reports success even when every statement was rejected.
psql_admin() {
  psql --no-psqlrc --quiet --no-align --tuples-only \
    -v ON_ERROR_STOP=1 \
    -h "$PG_URL" -p "$DB_PORT" -U "$db_admin_user" -d "$1" \
    -c "$2"
}

# Create the role, or reset its password if a previous checkout left it behind.
# CREATE ROLE on an existing name is a hard error, and PostgreSQL has no
# CREATE ROLE IF NOT EXISTS, hence the DO block. Reusing the role is safe: the
# password is replaced, so the credential from the earlier checkout stops working
# at this moment.
psql_admin "$DB_NAME" "
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_USER}') THEN
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${PG_USER}', '${db_user_password}');
  ELSE
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', '${PG_USER}', '${db_user_password}');
  END IF;
END
\$\$;" || finish 1

# Drop the temp role again if anything after this point fails
rollback() {
  psql_admin "$DB_NAME" "
    DROP OWNED BY \"${PG_USER}\" CASCADE;
    DROP ROLE IF EXISTS \"${PG_USER}\";" >/dev/null 2>&1
}

# Database-level rights, then schema-level. See the header note on PG 15.
psql_admin "$DB_NAME" "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${PG_USER}\";" \
  || { rollback; finish 1; }

psql_admin "$DB_NAME" "
  GRANT ALL ON SCHEMA public TO \"${PG_USER}\";
  GRANT ALL ON ALL TABLES IN SCHEMA public TO \"${PG_USER}\";
  GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO \"${PG_USER}\";" \
  || { rollback; finish 1; }

# ==============================
# Register the Bridge checkout
# ==============================
# native_auth=bridge_credentials: the user authenticates to the Bridge proxy
# with their bridge password (registered here from BRIDGE_AUTH_PASSWORD) and
# types it at the native psql password prompt. The temp role's password is
# carried separately as target_password (Bridge -> PostgreSQL auth).
AUTH_METHOD="password"
EXPIRES_AT=$(($(date +%s) + EXPIRATION))

jq -n \
  --arg transaction_id "$TRANSACTION_ID" \
  --arg username "$USER_EMAIL" \
  --arg target_host "$PG_URL" \
  --argjson target_port "$DB_PORT" \
  --arg target_username "$PG_USER" \
  --arg target_password "$db_user_password" \
  --arg target_database "$DB_NAME" \
  --argjson target_tls "$TARGET_TLS" \
  --argjson expires_at "$EXPIRES_AT" \
  --arg bridge_auth_password "$BRIDGE_AUTH_PASSWORD" \
  '{transaction_id: $transaction_id,
    protocol: "postgres",
    username: $username,
    target_host: $target_host,
    target_port: $target_port,
    target_username: $target_username,
    target_password: $target_password,
    target_database: $target_database,
    target_tls: $target_tls,
    native_auth: "bridge_credentials",
    bridge_auth_password: $bridge_auth_password,
    expires_at: $expires_at}' > "$payload"

if ! "${BROKER_API}" checkout-create --file "$payload" >/dev/null; then
  rollback
  finish 1
fi

# ==============================
# Output connection details
# ==============================
# Standard Bridge checkout output schema (shared across ssh/rdp/db checkouts
# so a single response template works for all):
#   BRIDGE_URL, command, auth_method, bridge_username,
#   bridge_port, target_username, browser_session
# One NLB fronts both the web tier and every native listener, so browser
# sessions and native psql clients use the SAME host -- BRIDGE_URL.
# The native login is <email>%<endpoint> (same identity as the owner): the part
# after % tells the Bridge which target this session is for.
BRIDGE_HOST="${BRIDGE_URL#https://}"
BRIDGE_HOST="${BRIDGE_HOST#http://}"
BRIDGE_HOST="${BRIDGE_HOST%%[:/]*}"
NATIVE_USER="${USER_EMAIL}%${PG_URL}"
# The connection string is quoted as one argument because the username contains
# '%' and '@': passing it as -U would work, but a URI would need them
# percent-encoded, and this form needs no encoding at all.
COMMAND="psql \"host=${BRIDGE_HOST} port=${NATIVE_PORT} user=${NATIVE_USER} dbname=${DB_NAME}\""
BROWSER_SESSION="https://${BRIDGE_HOST}/db/#transaction_id=${TRANSACTION_ID}"

jq -n \
  --arg BRIDGE_URL "$BRIDGE_HOST" \
  --arg command "$COMMAND" \
  --arg auth_method "$AUTH_METHOD" \
  --arg bridge_username "$NATIVE_USER" \
  --arg bridge_port "$NATIVE_PORT" \
  --arg target_username "$PG_USER" \
  --arg browser_session "$BROWSER_SESSION" \
  '{BRIDGE_URL: $BRIDGE_URL, command: $command,
    auth_method: $auth_method, bridge_username: $bridge_username,
    bridge_port: $bridge_port, target_username: $target_username,
    browser_session: $browser_session}'

finish 0
