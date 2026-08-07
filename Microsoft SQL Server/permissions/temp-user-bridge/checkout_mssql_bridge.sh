#!/bin/bash
#
# Britive checkout script: RDS SQL Server JIT login + Bridge proxied session
#
# Creates a temporary SQL Server LOGIN (server scope) plus a matching USER in
# the target database and adds it to a database role, then registers a database
# checkout with the Britive Bridge using the caller's BRIDGE CREDENTIALS
# (native_auth=bridge_credentials). The real SQL Server credentials never leave
# the broker/Bridge.
#
# Mirrors mysql_tempdba_checkout.sh. SQL Server differs from MySQL in two ways
# that matter here:
#   * There is no 'user'@'host' — access scope is the LOGIN (server) plus a
#     USER (per database). So there is no `host` env var; use DB_ROLE instead.
#   * Credentials are passed via SQLCMDPASSWORD (env), not a defaults file, so
#     they never appear in the process list.
#
# Bridge credential (provided by the broker as env vars):
#   BRIDGE_AUTH_PASSWORD - bridge password the user types at the native
#                          sqlcmd password prompt
#
# Identity: the native login username is the user's Britive identity (the email
# in `user`) -- the SAME value as the checkout owner. The Bridge matches BOTH
# the native username (before %) AND the browser SSO identity against the
# checkout's "username" field, so they must be identical. The profile "Bridge
# Username" field is NOT used for matching.
#
# Required env vars (set by Britive Resource Type / Profile):
#   user                 - requesting user's email (Britive auto-populates)
#   dburl                - RDS SQL Server endpoint hostname
#   secret               - AWS Secrets Manager secret ID holding admin {username, password}
#   TRX                  - Britive transaction ID
#   BRIDGE_URL           - Bridge hostname; one NLB serves browser and native sessions
#   EXPIRATION           - Checkout duration in seconds
#   BRIDGE_AUTH_PASSWORD - bridge password (see above)
#
# Optional env vars (with defaults):
#   DB_NAME     - database the temp USER is created in (default: systemdb)
#   DB_ROLE     - database role the temp USER joins (default: db_owner;
#                 use db_datareader / db_datawriter for least privilege)
#   DB_PORT     - SQL Server port on the target (default: 1433)
#   NATIVE_PORT - Bridge native MSSQL listener port (default: 1433)
#   TARGET_TLS  - true/false, TLS from Bridge to SQL Server (default: true)
#   DB_TRUST_SERVER_CERT - true to skip server-cert chain validation on the
#                 ADMIN connection (sqlcmd -C). Default false: the connection
#                 is encrypted (-N) AND the chain is verified against the
#                 system trust store, which already contains the RDS global
#                 bundle. Unlike the MySQL scripts
#                 there is no DB_CA_CERT — go-sqlcmd has no CA-file flag and
#                 uses the system store instead.
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   BROKER_API  - Path to broker-bridge-api.sh (default: /opt/britive-broker/scripts/broker-bridge-api.sh)
#
# NOTE ON NATIVE ACCESS: the v2 ECS stack registers NLB target groups for only
# ssh/rdp/mysql/postgres (ECS caps a service at 5 LB registrations). MSSQL is
# enabled in the container but has NO native listener, so the emitted `command`
# only works if you add an NLB listener + target group for 1433. The
# browser_session URL works either way.

set -u

# Sanitize SQL Server login name from email local part.
# Restricted to [A-Za-z0-9] so the name is always safe inside [brackets].
USER_EMAIL="${user}"
DB_LOGIN="${USER_EMAIL%%@*}"
DB_LOGIN="${DB_LOGIN//[^a-zA-Z0-9]/}"

MSSQL_URL="${dburl}"
SECRET="${secret}"
TRANSACTION_ID="${TRX}"
DB_NAME="${DB_NAME:-systemdb}"
DB_ROLE="${DB_ROLE:-db_owner}"
DB_PORT="${DB_PORT:-1433}"
NATIVE_PORT="${NATIVE_PORT:-1433}"
TARGET_TLS="${TARGET_TLS:-true}"
DB_TRUST_SERVER_CERT="${DB_TRUST_SERVER_CERT:-false}"
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

[ -n "$DB_LOGIN" ] || { echo "error: cannot derive login from: $USER_EMAIL" >&2; exit 1; }

command -v sqlcmd >/dev/null 2>&1 || { echo "error: sqlcmd not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }

# mktemp without --suffix: busybox (Alpine) does not support it
payload=$(mktemp) || exit 1
chmod 600 "$payload"
trap 'rm -f "$payload"' EXIT

finish () {
  exit "$1"
}

# Random password for the temp login -- only the Bridge ever sees it.
# Alphanumeric only (safe inside a single-quoted T-SQL literal); the fixed
# suffix guarantees SQL Server's CHECK_POLICY complexity requirement is met
# regardless of what the RNG produced.
#
# Source is openssl base64, NOT `tr -dc ... < /dev/urandom`: tr aborts with
# "Illegal byte sequence" on raw binary in any non-C locale, silently yielding
# a 1-2 character password instead of failing. The length assertion below
# turns any future generator regression into a hard error.
db_user_password="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)Aa1#"
if [ "${#db_user_password}" -ne 28 ]; then
  echo "error: password generation failed (got ${#db_user_password} chars, expected 28)" >&2
  exit 1
fi

# Fetch admin creds from Secrets Manager
secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text) || finish 1

db_admin_user=$(echo "$secret_value" | jq -r '.username')
db_admin_password=$(echo "$secret_value" | jq -r '.password')

# TLS to SQL Server: -N requests an encrypted connection. Without -C the
# server certificate chain IS verified against the system trust store (the
# image installs the RDS global bundle). -C trusts it blindly.
SQLCMD_TLS_OPTS=(-N)
if [ "$DB_TRUST_SERVER_CERT" = "true" ]; then
  SQLCMD_TLS_OPTS+=(-C)
fi

# -b makes sqlcmd exit non-zero on a T-SQL error (it returns 0 otherwise).
# SQLCMDPASSWORD keeps the admin password out of the process list.
run_admin_sql() {
  db="$1"
  SQLCMDPASSWORD="$db_admin_password" sqlcmd \
    -S "tcp:${MSSQL_URL},${DB_PORT}" \
    -U "$db_admin_user" \
    -d "$db" \
    "${SQLCMD_TLS_OPTS[@]}" \
    -b -l 15 -t 60 \
    -Q "$2"
}

# --- Create the server-level LOGIN (in master) ---
run_admin_sql master "
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '${DB_LOGIN}')
BEGIN
    CREATE LOGIN [${DB_LOGIN}] WITH PASSWORD = '${db_user_password}', DEFAULT_DATABASE = [${DB_NAME}];
    PRINT 'Created login: ${DB_LOGIN}';
END
ELSE
BEGIN
    ALTER LOGIN [${DB_LOGIN}] WITH PASSWORD = '${db_user_password}';
    PRINT 'Reset password for existing login: ${DB_LOGIN}';
END
" >&2 || finish 1

# --- Drop the temp principals again if a later step fails ---
rollback() {
  run_admin_sql "$DB_NAME" "
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '${DB_LOGIN}')
    DROP USER [${DB_LOGIN}];
" >/dev/null 2>&1
  run_admin_sql master "
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '${DB_LOGIN}')
    DROP LOGIN [${DB_LOGIN}];
" >/dev/null 2>&1
}

# --- Create the database USER and grant the role ---
run_admin_sql "$DB_NAME" "
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '${DB_LOGIN}')
BEGIN
    CREATE USER [${DB_LOGIN}] FOR LOGIN [${DB_LOGIN}];
    PRINT 'Created user: ${DB_LOGIN}';
END
ALTER ROLE [${DB_ROLE}] ADD MEMBER [${DB_LOGIN}];
PRINT 'Added to role: ${DB_ROLE}';
" >&2 || { rollback; finish 1; }

# ==============================
# Register the Bridge checkout
# ==============================
# native_auth=bridge_credentials: the user authenticates to the Bridge proxy
# with their bridge password (registered here from BRIDGE_AUTH_PASSWORD) and
# types it at the native sqlcmd password prompt. The temp SQL Server login
# password is carried separately as target_password (Bridge -> SQL Server auth).
AUTH_METHOD="password"
EXPIRES_AT=$(($(date +%s) + EXPIRATION))

jq -n \
  --arg transaction_id "$TRANSACTION_ID" \
  --arg username "$USER_EMAIL" \
  --arg target_host "$MSSQL_URL" \
  --argjson target_port "$DB_PORT" \
  --arg target_username "$DB_LOGIN" \
  --arg target_password "$db_user_password" \
  --arg target_database "$DB_NAME" \
  --argjson target_tls "$TARGET_TLS" \
  --argjson expires_at "$EXPIRES_AT" \
  --arg bridge_auth_password "$BRIDGE_AUTH_PASSWORD" \
  '{transaction_id: $transaction_id,
    protocol: "mssql",
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
# The native login is <email>%<mssql-endpoint> (same identity as the owner).
# See the NOTE ON NATIVE ACCESS in the header: `command` requires an NLB
# listener for 1433, which the v2 stack does not create by default.
BRIDGE_HOST="${BRIDGE_URL#https://}"
BRIDGE_HOST="${BRIDGE_HOST#http://}"
BRIDGE_HOST="${BRIDGE_HOST%%[:/]*}"
NATIVE_USER="${USER_EMAIL}%${MSSQL_URL}"
COMMAND="sqlcmd -S tcp:${BRIDGE_HOST},${NATIVE_PORT} -U '${NATIVE_USER}' -d ${DB_NAME} -N -C"
BROWSER_SESSION="https://${BRIDGE_HOST}/db/#transaction_id=${TRANSACTION_ID}"

jq -n \
  --arg BRIDGE_URL "$BRIDGE_HOST" \
  --arg command "$COMMAND" \
  --arg auth_method "$AUTH_METHOD" \
  --arg bridge_username "$NATIVE_USER" \
  --arg bridge_port "$NATIVE_PORT" \
  --arg target_username "$DB_LOGIN" \
  --arg browser_session "$BROWSER_SESSION" \
  '{BRIDGE_URL: $BRIDGE_URL, command: $command,
    auth_method: $auth_method, bridge_username: $bridge_username,
    bridge_port: $bridge_port, target_username: $target_username,
    browser_session: $browser_session}'

finish 0
