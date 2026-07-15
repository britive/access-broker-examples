#!/bin/bash
set -u

# ============================================================
# MySQL / Aurora MySQL IAM-Style Broker Scan
# ============================================================
# Runs on the Britive broker. Connects to a MySQL / Aurora MySQL
# endpoint with admin credentials from AWS Secrets Manager,
# enumerates local accounts, roles, role memberships, and each
# account's privilege grants, builds a JSON payload in the
# Britive Resource Manager schema, and writes it to the path
# supplied by the broker via environment variable.
#
# Required env vars:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH - full path for the JSON output file
#   dburl   - RDS / Aurora endpoint hostname
#   secret  - AWS Secrets Manager secret ID holding admin {username, password}
#
# Optional env vars (with defaults):
#   AWS_REGION          - Secrets Manager region (default: us-west-2)
#   DB_PORT             - MySQL port (default: 3306)
#   DB_CA_CERT          - path to the RDS CA bundle on the broker; enables
#                         server cert verification. Without it the connection
#                         is encrypted but the chain is not verified.
#                         Download: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
#   SCAN_EXCLUDE_USERS  - comma-separated User values to skip
#                         (default: mysql.infoschema,mysql.session,mysql.sys,rdsadmin,rdsrepladmin)
#   SCAN_INCLUDE_GRANTS - 1 to capture SHOW GRANTS per account into
#                         attributes.grants (default: 1; one query per account)
#
# Identity IDs use "user@host" (the MySQL account identifier) so that
# attribute_resolution.group_membership = "id" resolves correctly.
# MySQL 8+ roles (accounts appearing on the FROM side of
# mysql.role_edges) are emitted as groups, with their grantees as
# members. On engines without mysql.role_edges (MySQL 5.7), the
# groups array is empty.
# ============================================================

# ---- broker-side validation -------------------------------
if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
    echo "ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH not set. Cannot write scan output." >&2
    exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"

MYSQL_URL="${dburl:-}"
SECRET="${secret:-}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DB_PORT="${DB_PORT:-3306}"
DB_CA_CERT="${DB_CA_CERT:-}"
SCAN_EXCLUDE_USERS="${SCAN_EXCLUDE_USERS:-mysql.infoschema,mysql.session,mysql.sys,rdsadmin,rdsrepladmin}"
SCAN_INCLUDE_GRANTS="${SCAN_INCLUDE_GRANTS:-1}"

OUT_DIR="$(dirname "$OUTPUT_PATH")"
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- error JSON helper ------------------------------------
# write_error <message> -- always leaves a parseable JSON for the platform
write_error() {
    jq -n --arg msg "$1" --arg now "$NOW" '{
      data: { identities: [], groups: [], permissions: [], permission_mapping: [] },
      metadata: { scan_errors: $msg, scan_time: $now }
    }' > "$OUTPUT_PATH"
}

fail() {
    echo "ERROR: $1" >&2
    write_error "$1"
    exit 1
}

# ---- fail-fast checks -------------------------------------
command -v mysql >/dev/null 2>&1 || fail "mysql client not found on broker"
command -v aws   >/dev/null 2>&1 || fail "aws CLI not found on broker"
command -v jq    >/dev/null 2>&1 || fail "jq not found on broker"
[ -n "$MYSQL_URL" ] || fail "dburl env var not set"
[ -n "$SECRET" ]    || fail "secret env var not set"

echo "Running MySQL IAM-style broker scan against ${MYSQL_URL}..."
echo "Output path: $OUTPUT_PATH"

# ---- temp files & cleanup ---------------------------------
tmp_conf="$(mktemp)" || exit 1
IDENT_FILE="$(mktemp)"
GROUP_FILE="$(mktemp)"
chmod 600 "$tmp_conf"
trap 'rm -f "$tmp_conf" "$IDENT_FILE" "$GROUP_FILE"' EXIT INT TERM

# ---- fetch admin creds from Secrets Manager ---------------
secret_value=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text) || fail "failed to read secret ${SECRET} from Secrets Manager"

db_admin_user=$(echo "$secret_value" | jq -r '.username')
db_admin_password=$(echo "$secret_value" | jq -r '.password')

cat > "$tmp_conf" <<EOF
[client]
user = $db_admin_user
password = $db_admin_password
host = $MYSQL_URL
port = $DB_PORT
EOF

# TLS to Aurora: verify with DB_CA_CERT when provided, otherwise encrypt
# without chain verification (MariaDB 11.4+ clients verify by default and
# reject the RDS CA). Option names differ per client flavor.
if mysql --version 2>/dev/null | grep -qi mariadb; then
  if [ -n "$DB_CA_CERT" ]; then
    printf 'ssl-ca = %s\nssl-verify-server-cert = 1\n' "$DB_CA_CERT" >> "$tmp_conf"
  else
    printf 'ssl-verify-server-cert = 0\n' >> "$tmp_conf"
  fi
else
  if [ -n "$DB_CA_CERT" ]; then
    printf 'ssl-ca = %s\nssl-mode = VERIFY_CA\n' "$DB_CA_CERT" >> "$tmp_conf"
  else
    printf 'ssl-mode = REQUIRED\n' >> "$tmp_conf"
  fi
fi

mysql_query() {
    mysql --defaults-extra-file="$tmp_conf" -N -B -e "$1"
}

# escape a value for use inside single quotes in SQL
esc_sql() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# ---- connectivity check -----------------------------------
mysql_query "SELECT 1" >/dev/null 2>&1 || fail "cannot connect to MySQL at ${MYSQL_URL}:${DB_PORT}"

# ==========================================================
# ACCOUNTS - all rows in mysql.user
# ==========================================================
USERS="$(mysql_query "SELECT User, Host, account_locked, password_expired FROM mysql.user ORDER BY User, Host")" \
    || fail "failed to query mysql.user (admin account needs SELECT on mysql.*)"

# ==========================================================
# ROLE EDGES - MySQL 8+ role grants (absent on 5.7 -> empty)
# ==========================================================
ROLE_EDGES="$(mysql_query "SELECT FROM_USER, FROM_HOST, TO_USER, TO_HOST FROM mysql.role_edges" 2>/dev/null || true)"

# is_role <user> <host> -- true when the account is granted AS a role
is_role() {
    [ -n "$ROLE_EDGES" ] || return 1
    printf '%s\n' "$ROLE_EDGES" | awk -F'\t' -v u="$1" -v h="$2" '$1==u && $2==h {found=1} END {exit !found}'
}

# is_excluded <user> -- true when User is on the exclude list
is_excluded() {
    case ",${SCAN_EXCLUDE_USERS}," in
        *",$1,"*) return 0 ;;
        *)        return 1 ;;
    esac
}

# grants_for <user> <host> -- SHOW GRANTS joined with "; " (best-effort)
grants_for() {
    if [ "$SCAN_INCLUDE_GRANTS" = "1" ]; then
        mysql_query "SHOW GRANTS FOR '$(esc_sql "$1")'@'$(esc_sql "$2")'" 2>/dev/null | paste -sd';' - || true
    fi
}

# ==========================================================
# IDENTITIES - accounts that are not roles
# ==========================================================
echo "Scanning accounts..."
USER_COUNT=0

while IFS=$'\t' read -r u h locked expired; do
    [ -n "$u" ] || continue
    is_excluded "$u" && continue
    is_role "$u" "$h" && continue

    active=true
    [ "$locked" = "Y" ] && active=false

    jq -n \
      --arg id "${u}@${h}" \
      --arg user "$u" \
      --arg host "$h" \
      --arg now "$NOW" \
      --arg locked "$locked" \
      --arg expired "$expired" \
      --arg grants "$(grants_for "$u" "$h")" \
      --argjson active "$active" \
      '{
        id: $id,
        name: $id,
        type: "User",
        description: "MySQL local account",
        created_on: $now,
        is_active: $active,
        attributes: {
          username: $user,
          host: $host,
          account_locked: $locked,
          password_expired: $expired,
          grants: $grants
        }
      }' >> "$IDENT_FILE"
    USER_COUNT=$((USER_COUNT + 1))
done <<EOF
$USERS
EOF

echo "Found $USER_COUNT accounts."

# ==========================================================
# GROUPS - MySQL roles with their grantee members
# ==========================================================
echo "Scanning roles..."
GROUP_COUNT=0

ROLES="$(printf '%s\n' "$ROLE_EDGES" | awk -F'\t' 'NF {print $1 "\t" $2}' | sort -u)"

while IFS=$'\t' read -r ru rh; do
    [ -n "$ru" ] || continue
    is_excluded "$ru" && continue

    # members: grantees of this role that are not themselves roles
    MEMBERS_JSON="$(printf '%s\n' "$ROLE_EDGES" | \
        awk -F'\t' -v u="$ru" -v h="$rh" '$1==u && $2==h {print $3 "@" $4 "\t" $3 "\t" $4}' | \
        while IFS=$'\t' read -r mid mu mh; do
            is_role "$mu" "$mh" && continue
            jq -n --arg m "$mid" '$m'
        done | jq -s .)"
    [ -n "$MEMBERS_JSON" ] || MEMBERS_JSON="[]"

    # role account row from mysql.user (locked state, if readable)
    locked="$(printf '%s\n' "$USERS" | awk -F'\t' -v u="$ru" -v h="$rh" '$1==u && $2==h {print $3}')"

    jq -n \
      --arg id "${ru}@${rh}" \
      --arg user "$ru" \
      --arg host "$rh" \
      --arg now "$NOW" \
      --arg locked "${locked:-}" \
      --arg grants "$(grants_for "$ru" "$rh")" \
      --argjson members "$MEMBERS_JSON" \
      '{
        id: $id,
        name: $id,
        type: "User group",
        description: "MySQL role",
        created_on: $now,
        is_active: true,
        members: $members,
        attributes: {
          rolename: $user,
          host: $host,
          account_locked: $locked,
          grants: $grants
        }
      }' >> "$GROUP_FILE"
    GROUP_COUNT=$((GROUP_COUNT + 1))
done <<EOF
$ROLES
EOF

echo "Found $GROUP_COUNT roles."

# ==========================================================
# BUILD OUTPUT - assemble the Britive Resource Manager schema
# ==========================================================
jq -n \
  --slurpfile identities <(cat "$IDENT_FILE"; true) \
  --slurpfile groups     <(cat "$GROUP_FILE"; true) \
  --arg resource_id "$MYSQL_URL" \
  --arg now "$NOW" \
  --arg details "MySQL scan completed. Accounts: ${USER_COUNT}, Roles: ${GROUP_COUNT}" \
  '{
    data: {
      identities: $identities,
      groups: $groups,
      permissions: [],
      permission_mapping: []
    },
    metadata: {
      resource_id: $resource_id,
      resource_type: "MySQL",
      scan_time: $now,
      scan_details: $details,
      scan_errors: "",
      attribute_resolution: {
        group_membership: "id",
        permission_mapping: "id"
      }
    }
  }' > "$OUTPUT_PATH" || fail "failed to assemble scan output JSON"

echo "MySQL broker scan completed successfully."
exit 0
