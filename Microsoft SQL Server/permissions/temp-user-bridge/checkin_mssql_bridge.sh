#!/bin/bash
#
# Britive checkin script: RDS SQL Server JIT login removal + Bridge teardown
#
# Deletes the Bridge checkout FIRST so the proxied session closes, then kills
# any lingering server sessions for the temp login and drops the database USER
# and the server LOGIN created at checkout.
#
# Mirrors mysql_tempdba_checkin.sh. SQL Server needs the teardown in reverse
# dependency order (sessions -> database USER -> server LOGIN); DROP LOGIN
# fails while the principal still owns sessions or a database user.
#
# Required env vars (set by Britive Resource Type / Profile):
#   user    - requesting user's email (Britive auto-populates)
#   dburl   - RDS SQL Server endpoint hostname
#   secret  - AWS Secrets Manager secret ID holding admin {username, password}
#   TRX     - Britive transaction ID (matches the checkout TRX)
#
# Optional env vars (with defaults):
#   DB_NAME     - database the temp USER lives in (must match checkout;
#                 default: systemdb)
#   DB_PORT     - SQL Server port on the target (default: 1433)
#   DB_TRUST_SERVER_CERT - true to skip server-cert chain validation (sqlcmd -C).
#                 Default false: encrypted (-N) and verified against the system
#                 trust store. See the checkout script header.
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   BROKER_API  - Path to broker-bridge-api.sh (default: /opt/britive-broker/scripts/broker-bridge-api.sh)

set -u

# Sanitize SQL Server login name from email local part -- must match checkout logic
DB_LOGIN="${user%%@*}"
DB_LOGIN="${DB_LOGIN//[^a-zA-Z0-9]/}"

MSSQL_URL="${dburl}"
SECRET="${secret}"
TRANSACTION_ID="${TRX}"
DB_NAME="${DB_NAME:-systemdb}"
DB_PORT="${DB_PORT:-1433}"
DB_TRUST_SERVER_CERT="${DB_TRUST_SERVER_CERT:-false}"
AWS_REGION="${AWS_REGION:-us-west-2}"
BROKER_API="${BROKER_API:-/opt/britive-broker/scripts/broker-bridge-api.sh}"

finish () {
  exit "$1"
}

[ -n "$DB_LOGIN" ] || { echo "error: cannot derive login from: ${user}" >&2; finish 1; }

command -v sqlcmd >/dev/null 2>&1 || { echo "error: sqlcmd not found" >&2; finish 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; finish 1; }

rc=0

# --- Terminate the Bridge session first ---
"${BROKER_API}" checkout-delete "${TRANSACTION_ID}" || rc=1
echo "[checkin] Bridge session terminated" >&2

secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text) || finish 1

db_admin_user=$(echo "$secret_value" | jq -r '.username')
db_admin_password=$(echo "$secret_value" | jq -r '.password')

SQLCMD_TLS_OPTS=(-N)
if [ "$DB_TRUST_SERVER_CERT" = "true" ]; then
  SQLCMD_TLS_OPTS+=(-C)
fi

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

# --- Kill lingering sessions for the temp login (best effort) ---
# DROP LOGIN fails while the principal has open sessions. Requires processadmin,
# which the RDS master user holds.
run_admin_sql master "
SET NOCOUNT ON;
DECLARE @kill nvarchar(max) = N'';
SELECT @kill = @kill + N'KILL ' + CAST(session_id AS nvarchar(10)) + N';'
FROM sys.dm_exec_sessions
WHERE login_name = '${DB_LOGIN}';
IF LEN(@kill) > 0 EXEC(@kill);
" >/dev/null 2>&1 || echo "[checkin] warning: could not kill sessions for ${DB_LOGIN}" >&2

# --- Drop the database USER, then the server LOGIN ---
run_admin_sql "$DB_NAME" "
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '${DB_LOGIN}')
BEGIN
    DROP USER [${DB_LOGIN}];
    PRINT 'Dropped user: ${DB_LOGIN}';
END
" >&2 || rc=1

run_admin_sql master "
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '${DB_LOGIN}')
BEGIN
    DROP LOGIN [${DB_LOGIN}];
    PRINT 'Dropped login: ${DB_LOGIN}';
END
" >&2 || rc=1

echo "[checkin] login removed" >&2
finish "$rc"
