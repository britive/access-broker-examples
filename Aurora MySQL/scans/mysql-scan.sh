#!/bin/sh
set -eu

# ============================================================
# MySQL / Aurora IAM-Style Broker Scan
# ============================================================
# Runs on the Britive broker. Connects to a MySQL / Aurora RDS
# instance with vaulted admin credentials, enumerates database
# accounts (mysql.user) and roles (mysql.role_edges), builds a
# JSON payload in the Britive Resource Manager schema, and writes
# it to the path supplied by the broker.
#
# Identities  = login accounts in mysql.user
# Groups      = MySQL roles (accounts granted to others via
#               mysql.role_edges); members are the grantees
# Permissions = defined in the resource type, so left empty here
#
# Broker-injected resource params (plaintext env vars):
#   RESOURCE_URL                 - RDS / Aurora endpoint hostname   (required)
#   RESOURCE_AWSSECRETID         - Secrets Manager secret ID holding
#                                  admin {username, password}       (required)
#   RESOURCE_AWS_SECRET_REGION   - AWS region of the secret         (default: us-west-2)
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH - full path for JSON output    (required)
#
# Optional:
#   DB_PORT      - MySQL port (default: 3306)
#   DB_CA_CERT   - path to the RDS CA bundle on the broker; enables
#                  server cert verification. Without it the connection
#                  is encrypted but the chain is not verified.
#                  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
#
# Identity IDs are "user@host" so that
# attribute_resolution.group_membership = "id" resolves against the
# grantee references in mysql.role_edges.
# ============================================================

# ---- broker-side validation -------------------------------
if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
    echo "ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH not set. Cannot write scan output." >&2
    exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"

# Broker uppercases resource param names; tolerate the mixed-case form too.
DB_URL="${RESOURCE_URL:-}"
SECRET_ID="${RESOURCE_AWSSECRETID:-${RESOURCE_AWSsecretID:-}}"
SECRET_REGION="${RESOURCE_AWS_SECRET_REGION:-us-west-2}"
DB_PORT="${DB_PORT:-3306}"
DB_CA_CERT="${DB_CA_CERT:-}"

OUT_DIR="$(dirname "$OUTPUT_PATH")"
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"

# ---- error JSON helper ------------------------------------
# write_error <message>
write_error() {
    _msg="$1"
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg e "$_msg" --arg t "$_now" \
          '{data:{identities:[],groups:[],permissions:[],permission_mapping:[]},
            metadata:{scan_errors:$e,scan_time:$t}}' > "$OUTPUT_PATH"
    else
        _esc="$(printf '%s' "$_msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
        cat > "$OUTPUT_PATH" <<EOF
{
  "data": { "identities": [], "groups": [], "permissions": [], "permission_mapping": [] },
  "metadata": { "scan_errors": "$_esc", "scan_time": "$_now" }
}
EOF
    fi
}

# ---- fail-fast checks -------------------------------------
for cmd in mysql aws jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        write_error "required command not found on broker: $cmd"
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    }
done
[ -n "$DB_URL" ]    || { write_error "RESOURCE_URL empty"; echo "ERROR: RESOURCE_URL empty" >&2; exit 1; }
[ -n "$SECRET_ID" ] || { write_error "RESOURCE_AWSSECRETID empty"; echo "ERROR: RESOURCE_AWSSECRETID empty" >&2; exit 1; }

echo "Running MySQL IAM-style broker scan against $DB_URL..." >&2
echo "Output path: $OUTPUT_PATH" >&2

# ---- temp files with restrictive perms --------------------
TMP_CONF="$(mktemp)"
USERS_FILE="$(mktemp)"
EDGES_FILE="$(mktemp)"
chmod 600 "$TMP_CONF" "$USERS_FILE" "$EDGES_FILE"
trap 'rm -f "$TMP_CONF" "$USERS_FILE" "$EDGES_FILE"' EXIT INT TERM

# ---- fetch admin creds from Secrets Manager ---------------
SECRET_VALUE="$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --region "$SECRET_REGION" \
    --query 'SecretString' \
    --output text 2>/dev/null)" || {
    write_error "failed to read secret $SECRET_ID from Secrets Manager ($SECRET_REGION)"
    echo "ERROR: Secrets Manager read failed" >&2
    exit 1
}

DB_ADMIN_USER="$(printf '%s' "$SECRET_VALUE" | jq -r '.username')"
DB_ADMIN_PASSWORD="$(printf '%s' "$SECRET_VALUE" | jq -r '.password')"
if [ -z "$DB_ADMIN_USER" ] || [ "$DB_ADMIN_USER" = "null" ]; then
    write_error "secret $SECRET_ID missing 'username'/'password' keys"
    echo "ERROR: secret missing username/password" >&2
    exit 1
fi

# ---- build [client] config (no quotes; mysql reads values literally) ----
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

# ---- query accounts and role edges ------------------------
# -B batch (tab-separated), -N no column headers, -r raw (no escaping).
if ! mysql --defaults-extra-file="$TMP_CONF" -B -N -r -e \
    "SELECT User, Host, account_locked, password_expired, plugin FROM mysql.user ORDER BY User, Host;" \
    > "$USERS_FILE" 2>"$USERS_FILE.err"; then
    write_error "mysql.user query failed: $(cat "$USERS_FILE.err" 2>/dev/null)"
    rm -f "$USERS_FILE.err"
    echo "ERROR: mysql.user query failed" >&2
    exit 1
fi
rm -f "$USERS_FILE.err"

# role_edges only exists on MySQL 8.0+; treat its absence as "no roles".
mysql --defaults-extra-file="$TMP_CONF" -B -N -r -e \
    "SELECT FROM_USER, FROM_HOST, TO_USER, TO_HOST FROM mysql.role_edges ORDER BY FROM_USER, FROM_HOST;" \
    > "$EDGES_FILE" 2>/dev/null || : > "$EDGES_FILE"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- assemble Britive Resource Manager schema with jq -----
# A MySQL role is an account that is granted to others (appears as FROM in
# role_edges). Such accounts become groups; the rest are user identities.
# NOTE: a role with no grantees is indistinguishable from a user here and is
# reported as a user.
jq -n \
  --arg now "$NOW" \
  --arg resource_id "$DB_URL" \
  --rawfile users_raw "$USERS_FILE" \
  --rawfile edges_raw "$EDGES_FILE" \
  '
  def rows($raw): $raw | split("\n") | map(select(length > 0) | split("\t"));
  rows($users_raw) as $u
  | rows($edges_raw) as $e
  | ($e | map(.[0] + "@" + .[1]) | unique) as $roleIds
  | ($u | map({
        id:     (.[0] + "@" + .[1]),
        user:   .[0],
        host:   .[1],
        locked: .[2],
        pwexp:  .[3],
        plugin: .[4]
    })) as $accts
  | {
      data: {
        identities: ($accts
          | map(select(.id as $iid | ($roleIds | index($iid)) == null))
          | map({
              id:          .id,
              name:        .user,
              type:        "User",
              description: "MySQL database user",
              created_on:  $now,
              is_active:   (.locked != "Y"),
              attributes: {
                username:          .user,
                email:             (.user + "@" + $resource_id),
                host:              .host,
                account_locked:    .locked,
                password_expired:  .pwexp,
                auth_plugin:       .plugin
              }
            })),
        groups: ($accts
          | map(select(.id as $iid | ($roleIds | index($iid)) != null))
          | map(. as $r
              | ($e
                  | map(select(.[0] == $r.user and .[1] == $r.host) | (.[2] + "@" + .[3])))
                as $members
              | {
                  id:          $r.id,
                  name:        $r.user,
                  type:        "User group",
                  description: "MySQL role",
                  created_on:  $now,
                  is_active:   true,
                  members:     $members,
                  attributes: {
                    rolename: $r.user,
                    host:     $r.host
                  }
                })),
        permissions: [],
        permission_mapping: []
      },
      metadata: {
        resource_id:   $resource_id,
        resource_type: "MySQLDB",
        scan_time:     $now,
        scan_details:  ("MySQL scan completed on " + $resource_id + "."),
        scan_errors:   "",
        attribute_resolution: {
          group_membership:   "id",
          permission_mapping: "id"
        }
      }
    }
  ' > "$OUTPUT_PATH"

USER_COUNT="$(jq '.data.identities | length' "$OUTPUT_PATH")"
ROLE_COUNT="$(jq '.data.groups | length' "$OUTPUT_PATH")"
echo "MySQL broker scan completed successfully. Users: $USER_COUNT, Roles: $ROLE_COUNT" >&2
exit 0
