#!/bin/sh
set -eu

# ============================================================
# MySQL / Aurora Account Password Rotation
# ============================================================
# Rotates the password of a MySQL / Aurora database account by
# connecting with vaulted admin credentials (AWS Secrets Manager)
# and running ALTER USER. Mirrors the connection contract of the
# MySQL scan script; the account to rotate and the new password
# are injected by the broker.
#
# The Britive account name is the native MySQL identity
# "user@host" (e.g. "readonly_user@%"). It is split on the last
# '@' into the user and host parts for ALTER USER 'user'@'host'.
#
# Required env vars:
#   RESOURCE_URL                 - RDS / Aurora endpoint hostname
#   RESOURCE_AWSSECRETID         - Secrets Manager secret ID holding the
#                                  ADMIN {username, password} used to connect
#   RESOURCE_ACCOUNT_NAME        - account to rotate, "user@host"
#                                  (e.g. "readonly_user@%")
#   NEW_PASSWORD                 - the new password to set on the account
#
# Optional env vars:
#   RESOURCE_AWS_SECRET_REGION   - AWS region of the secret (default: us-west-2)
#   DB_PORT                      - MySQL port (default: 3306)
#   DB_CA_CERT                   - path to the RDS CA bundle on the broker;
#                                  enables server cert verification. Without it
#                                  the connection is encrypted but the chain is
#                                  not verified.
#                                  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
#
# The new password is never logged and is sent to mysql over stdin
# (never on the command line / process list).
# ============================================================

fail() { echo "rotation FAILED: $1" >&2; exit 1; }

# ---- validate required inputs -----------------------------
DB_URL="${RESOURCE_URL:-}"
SECRET_ID="${RESOURCE_AWSSECRETID:-${RESOURCE_AWSsecretID:-}}"
ACCOUNT_NAME="${RESOURCE_ACCOUNT_NAME:-}"
NEW_PASSWORD="${NEW_PASSWORD:-}"
SECRET_REGION="${RESOURCE_AWS_SECRET_REGION:-us-west-2}"
DB_PORT="${DB_PORT:-3306}"
DB_CA_CERT="${DB_CA_CERT:-}"

[ -n "$DB_URL" ]       || fail "RESOURCE_URL not set."
[ -n "$SECRET_ID" ]    || fail "RESOURCE_AWSSECRETID not set."
[ -n "$ACCOUNT_NAME" ] || fail "RESOURCE_ACCOUNT_NAME not set (expected 'user@host')."
[ -n "$NEW_PASSWORD" ] || fail "NEW_PASSWORD not set. Cannot rotate."

for cmd in mysql aws jq; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command not found on broker: $cmd"
done

# ---- split "user@host" on the LAST '@' --------------------
# A MySQL account is user@host; the username itself may contain '@',
# so split on the final '@'. If there is no '@', default host to '%'.
case "$ACCOUNT_NAME" in
    *@*)
        DB_USER="${ACCOUNT_NAME%@*}"
        DB_HOST="${ACCOUNT_NAME##*@}"
        ;;
    *)
        DB_USER="$ACCOUNT_NAME"
        DB_HOST="%"
        ;;
esac
[ -n "$DB_USER" ] || fail "could not parse username from RESOURCE_ACCOUNT_NAME='$ACCOUNT_NAME'."
[ -n "$DB_HOST" ] || DB_HOST="%"

echo "Starting MySQL account password rotation..." >&2
echo "  Endpoint : $DB_URL" >&2
echo "  Account  : ${DB_USER}@${DB_HOST}" >&2

# ---- temp files with restrictive perms --------------------
TMP_CONF="$(mktemp)"
chmod 600 "$TMP_CONF"
trap 'rm -f "$TMP_CONF"' EXIT INT TERM

# ---- fetch admin creds from Secrets Manager ---------------
SECRET_VALUE="$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --region "$SECRET_REGION" \
    --query 'SecretString' \
    --output text 2>/dev/null)" || fail "failed to read secret $SECRET_ID from Secrets Manager ($SECRET_REGION)."

DB_ADMIN_USER="$(printf '%s' "$SECRET_VALUE" | jq -r '.username')"
DB_ADMIN_PASSWORD="$(printf '%s' "$SECRET_VALUE" | jq -r '.password')"
[ -n "$DB_ADMIN_USER" ] && [ "$DB_ADMIN_USER" != "null" ] || fail "secret $SECRET_ID missing 'username'/'password' keys."

# ---- build [client] config (creds never on the command line) ----
cat > "$TMP_CONF" <<EOF
[client]
user = $DB_ADMIN_USER
password = $DB_ADMIN_PASSWORD
host = $DB_URL
port = $DB_PORT
EOF

# TLS: newer MariaDB clients verify the server cert by default and reject the
# RDS CA. Verify against DB_CA_CERT when provided; otherwise stay encrypted but
# skip chain verification. Option names differ per client flavor.
if mysql --version 2>/dev/null | grep -qi mariadb; then
    if [ -n "$DB_CA_CERT" ]; then
        printf 'ssl-ca = %s\nssl-verify-server-cert = 1\n' "$DB_CA_CERT" >> "$TMP_CONF"
    else
        printf 'ssl-verify-server-cert = 0\n' >> "$TMP_CONF"
    fi
else
    if [ -n "$DB_CA_CERT" ]; then
        printf 'ssl-ca = %s\nssl-mode = VERIFY_CA\n' "$DB_CA_CERT" >> "$TMP_CONF"
    else
        printf 'ssl-mode = REQUIRED\n' >> "$TMP_CONF"
    fi
fi

# ---- SQL-escape identifiers and the new password ----------
# MySQL string literals: escape backslash first, then single quote.
sql_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }
USER_ESC="$(sql_escape "$DB_USER")"
HOST_ESC="$(sql_escape "$DB_HOST")"
PW_ESC="$(sql_escape "$NEW_PASSWORD")"

# ---- verify the account exists ----------------------------
EXISTS="$(mysql --defaults-extra-file="$TMP_CONF" -B -N -e \
    "SELECT COUNT(*) FROM mysql.user WHERE User = '$USER_ESC' AND Host = '$HOST_ESC';" 2>/dev/null)" \
    || fail "could not query mysql.user (check admin privileges / connectivity)."
[ "$EXISTS" = "1" ] || fail "account '${DB_USER}'@'${DB_HOST}' does not exist on $DB_URL."

# ---- rotate the password ----------------------------------
# Statement is piped over stdin so the new password never appears in the
# process list or shell history.
printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$USER_ESC" "$HOST_ESC" "$PW_ESC" \
    | mysql --defaults-extra-file="$TMP_CONF" \
    || fail "ALTER USER failed for '${DB_USER}'@'${DB_HOST}'."

echo "MySQL account password rotation completed successfully." >&2
echo "  Account : ${DB_USER}@${DB_HOST}" >&2
echo "  Endpoint: $DB_URL" >&2
exit 0
