#!/bin/bash
# ==============================================================================
# Britive MySQL scan: accounts and roles -> Resource Manager JSON
# ==============================================================================
# Enumerates MySQL/Aurora accounts and roles over the wire from the Bridge broker
# and writes the Resource Manager scan payload. READ ONLY: nothing but SELECTs.
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  (required) where to write the JSON
#
# ------------------------------------------------------------------------------
# RESOURCE ATTRIBUTES
# ------------------------------------------------------------------------------
# A scan runs against a resource, and the broker injects that resource's
# attributes with a RESOURCE_ prefix:
#
#   Attribute        | Arrives as                | Meaning
#   -----------------|---------------------------|----------------------------
#   DBURL            | RESOURCE_DBURL            | RDS/Aurora endpoint hostname
#   ADMIN_USER       | RESOURCE_ADMIN_USER       | admin login (optional; falls back
#                    |                           | to the secret's username field)
#   AWS_SECRET_NAME  | RESOURCE_AWS_SECRET_NAME  | Secrets Manager id holding
#                    |                           | {username, password} for admin
#
# Setting DBURL / SECRET_NAME directly overrides them, so this stays runnable by
# hand for testing.
#
# Optional env vars:
#   DB_PORT     - MySQL port (default: 3306)
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   DB_CA_CERT  - RDS CA bundle path; enables server-cert verification. Without it
#                 the connection is still encrypted but the chain is not verified.
#                 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
#
# ------------------------------------------------------------------------------
# WHAT MAPS ONTO WHAT
# ------------------------------------------------------------------------------
#   data.identities   one per account, id = 'user@host' -- MySQL identity is the
#                     PAIR, so 'app'@'10.0.0.1' and 'app'@'%' are different
#                     accounts with different grants. Using the bare user name as
#                     the id would merge them and hand out the wrong access.
#   data.groups       one per ROLE (MySQL 8.0+), members from mysql.role_edges
#   data.permissions  empty -- see the note below
#   data.permission_mapping  empty -- role membership lives in groups.members
#
# Privileges are deliberately NOT enumerated. A full grant dump is one row per
# user per database per table per column; on a real schema that is tens of
# thousands of rows, it changes on every DDL, and Resource Manager has nothing to
# do with it. Roles are the useful unit of access here.
#
# Pre-8.0 servers have no roles: mysql.role_edges does not exist, groups comes
# back empty, and that is reported in scan_details rather than failing.
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Output path first: without it there is nowhere to report any later failure.
# ------------------------------------------------------------------------------
if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
  printf 'ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH is not set; cannot write scan output.\n' >&2
  exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"
mkdir -p "$(dirname "$OUTPUT_PATH")" \
  || { printf 'ERROR: cannot create output directory for %s\n' "$OUTPUT_PATH" >&2; exit 1; }

LOG_TAG="mysql-scan"
TRACE=""

# INFO is buffered and the error prints FIRST: Britive keeps only about the first
# 250 characters of captured output, so a run that logs progress first has its
# actual failure truncated away. SCAN_VERBOSE=true restores live logging.
info() {
  if [ "${SCAN_VERBOSE:-false}" = "true" ]; then
    printf '%s [%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_TAG" "$1" >&2
  else
    TRACE="${TRACE}${1}; "
  fi
}

# Every exit path must leave valid JSON at OUTPUT_PATH: the broker parses that
# file to learn what happened, and a missing one reports as an opaque failure.
write_scan_error() {
  python3 -c '
import json
import sys

message, path, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "data": {"identities": [], "groups": [], "permissions": [], "permission_mapping": []},
    "metadata": {"scan_errors": message, "scan_time": stamp},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
' "$1" "$OUTPUT_PATH" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" 2>/dev/null \
    || printf '{"data":{"identities":[],"groups":[],"permissions":[],"permission_mapping":[]},"metadata":{"scan_errors":"scan failed and the error payload could not be encoded","scan_time":""}}' > "$OUTPUT_PATH"
}

die() {
  printf '%s [%s] ERROR %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_TAG" "$*" >&2
  [ -n "$TRACE" ] && printf 'trace: %s\n' "$TRACE" >&2
  write_scan_error "$*"
  exit 1
}

SCAN_COMPLETED=false
TMP_DIR=""
cleanup() {
  local rc=$?
  if [ "$SCAN_COMPLETED" != "true" ] && [ ! -s "$OUTPUT_PATH" ]; then
    write_scan_error "scan aborted unexpectedly (exit ${rc}); trace: ${TRACE:-<empty>}"
  fi
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Resource attributes.
# ------------------------------------------------------------------------------
DBURL="${DBURL:-${RESOURCE_DBURL:-}}"
SECRET_NAME="${SECRET_NAME:-${RESOURCE_AWS_SECRET_NAME:-}}"
DB_PORT="${DB_PORT:-3306}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DB_CA_CERT="${DB_CA_CERT:-}"
DB_ADMIN_USER_ATTR="${DB_ADMIN_USER:-${RESOURCE_ADMIN_USER:-}}"

[ -n "$DBURL" ] \
  || die "no database endpoint: set the resource's DBURL attribute (arrives as RESOURCE_DBURL), or DBURL when running by hand"
[ -n "$SECRET_NAME" ] \
  || die "no admin credential: set the resource's AWS_SECRET_NAME attribute (arrives as RESOURCE_AWS_SECRET_NAME)"

for cmd in mysql aws jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "broker is missing required command: ${cmd}"
done

info "scan target ${DBURL}:${DB_PORT}, output ${OUTPUT_PATH}"

TMP_DIR="$(mktemp -d)" || die "mktemp -d failed (no writable TMPDIR?)"
chmod 700 "$TMP_DIR"

# ------------------------------------------------------------------------------
# Admin credentials. Written to a 0600 defaults-file and passed with
# --defaults-extra-file: the password is NEVER on the command line, where
# /proc/<pid>/cmdline would expose it to everything in the container.
# ------------------------------------------------------------------------------
info "reading admin credentials from Secrets Manager id '${SECRET_NAME}' (${AWS_REGION})"
SECRET_JSON="$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
    --query SecretString --output text 2>/dev/null)" \
  || die "cannot read secret '${SECRET_NAME}' in ${AWS_REGION} (check the task role's secretsmanager:GetSecretValue permission)"

# The admin username can come from the resource's ADMIN_USER attribute OR from the
# secret. The attribute wins, so a secret holding only {"password": ...} is fine --
# which is how these resources are set up (RESOURCE_ADMIN_USER=admin).
DB_ADMIN_USER="${DB_ADMIN_USER_ATTR:-$(printf '%s' "$SECRET_JSON" | jq -r '.username // empty')}"
DB_ADMIN_PASSWORD="$(printf '%s' "$SECRET_JSON" | jq -r '.password // empty')"
unset SECRET_JSON
[ -n "$DB_ADMIN_PASSWORD" ] \
  || die "secret '${SECRET_NAME}' has no 'password' field"
[ -n "$DB_ADMIN_USER" ] \
  || die "no admin username: set the resource's ADMIN_USER attribute (arrives as RESOURCE_ADMIN_USER), or put a 'username' field in secret '${SECRET_NAME}'"

MY_CNF="${TMP_DIR}/my.cnf"
# No quotes around the values: the [client] section treats them literally.
( umask 077; cat > "$MY_CNF" <<EOF
[client]
user = $DB_ADMIN_USER
password = $DB_ADMIN_PASSWORD
host = $DBURL
port = $DB_PORT
connect_timeout = 15
EOF
) || die "cannot write the MySQL defaults file"
unset DB_ADMIN_PASSWORD

# TLS: newer MariaDB clients verify the server certificate by default and reject
# the RDS CA ("self-signed certificate in certificate chain"). Option names differ
# per client flavour, so branch on which one is installed.
if mysql --version 2>/dev/null | grep -qi mariadb; then
  if [ -n "$DB_CA_CERT" ]; then
    printf 'ssl-ca = %s\nssl-verify-server-cert = 1\n' "$DB_CA_CERT" >> "$MY_CNF"
  else
    printf 'ssl-verify-server-cert = 0\n' >> "$MY_CNF"
  fi
else
  if [ -n "$DB_CA_CERT" ]; then
    printf 'ssl-ca = %s\nssl-mode = VERIFY_CA\n' "$DB_CA_CERT" >> "$MY_CNF"
  else
    printf 'ssl-mode = REQUIRED\n' >> "$MY_CNF"
  fi
fi

# mysql_query <sql> — tab-separated rows, no header, no column alignment.
# --batch also escapes tabs/newlines inside values as \t and \n, so one row is
# always one line and the parser cannot be fooled by a name containing whitespace.
mysql_query() {
  mysql --defaults-extra-file="$MY_CNF" --batch --skip-column-names -e "$1"
}

info "connecting"
SERVER_VERSION="$(mysql_query "SELECT VERSION();" 2>"${TMP_DIR}/connect.err")" \
  || die "cannot connect to ${DBURL}:${DB_PORT} as '${DB_ADMIN_USER}': $(tr '\n' ' ' < "${TMP_DIR}/connect.err" | cut -c1-200)"
info "server version ${SERVER_VERSION}"

# ------------------------------------------------------------------------------
# Accounts. account_locked and password_expired both make an account unusable, so
# either one maps to is_active=false.
# ------------------------------------------------------------------------------
USERS_TSV="${TMP_DIR}/users.tsv"
mysql_query "
  SELECT user, host, account_locked, password_expired
    FROM mysql.user
   ORDER BY user, host;" > "$USERS_TSV" 2>"${TMP_DIR}/users.err" \
  || die "cannot read mysql.user (the admin account needs SELECT on it): $(tr '\n' ' ' < "${TMP_DIR}/users.err" | cut -c1-200)"

# ------------------------------------------------------------------------------
# Roles. mysql.role_edges is MySQL 8.0+; its absence is normal, not an error.
# ------------------------------------------------------------------------------
ROLES_TSV="${TMP_DIR}/roles.tsv"
ROLES_SUPPORTED=true
if ! mysql_query "
      SELECT CONCAT(from_user, '@', from_host) AS role,
             CONCAT(to_user,   '@', to_host)   AS member
        FROM mysql.role_edges
       ORDER BY role, member;" > "$ROLES_TSV" 2>/dev/null; then
  ROLES_SUPPORTED=false
  : > "$ROLES_TSV"
  info "mysql.role_edges unavailable (pre-8.0 server, or no SELECT on it) -- groups will be empty"
fi

info "users $(wc -l < "$USERS_TSV" | tr -d ' '), role edges $(wc -l < "$ROLES_TSV" | tr -d ' ')"

# ------------------------------------------------------------------------------
# Assemble the payload. python stdlib only, no pip dependency on the broker.
# ------------------------------------------------------------------------------
SCAN_JSON="${TMP_DIR}/scan.json"

DBURL="$DBURL" \
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
USERS_TSV="$USERS_TSV" \
ROLES_TSV="$ROLES_TSV" \
ROLES_SUPPORTED="$ROLES_SUPPORTED" \
SERVER_VERSION="$SERVER_VERSION" \
OUT_JSON="$SCAN_JSON" \
python3 <<'PYEOF'
import json
import os
import re

# --batch escapes these inside values; undo them so names round-trip exactly.
UNESCAPE = (("\\t", "\t"), ("\\n", "\n"), ("\\\\", "\\"))


def unescape(value):
    for old, new in UNESCAPE:
        value = value.replace(old, new)
    return value


def read_tsv(path, width):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) < width:
                continue
            rows.append([unescape(f) for f in fields[:width]])
    return rows


dburl = os.environ["DBURL"]
now = os.environ["NOW"]
roles_supported = os.environ["ROLES_SUPPORTED"] == "true"

# The platform's account table has NOT NULL email, first_name and last_name
# columns -- an identity without them fails the import with
# "Column 'email' cannot be null" after an otherwise successful scan. These
# accounts have no such thing, so a stable synthetic address is derived from the
# id. Same approach the AD scan uses when a directory entry has no mail attribute.
#
# The whole id goes into the local part, not just the user name: MySQL
# 'app'@'%' and 'app'@'10.0.0.5' are different accounts, and collapsing them onto
# one address would collide if the platform treats email as unique.
def synth_email(identity_id, domain):
    local = re.sub(r"[^A-Za-z0-9._-]+", "-", identity_id).strip("-.")
    return f"{local or 'account'}@{domain}"


# A MySQL account is the (user, host) pair. Roles live in the same table, so the
# role_edges "from" side tells us which rows are roles rather than logins.
role_ids = set()
for role, _member in read_tsv(os.environ["ROLES_TSV"], 2):
    role_ids.add(role)

identities = []
locked = 0
for user, host, account_locked, password_expired in read_tsv(os.environ["USERS_TSV"], 4):
    account_id = f"{user}@{host}"
    if account_id in role_ids:
        # It is a role; it is reported as a group below, not as an identity.
        continue
    is_active = account_locked != "Y" and password_expired != "Y"
    if not is_active:
        locked += 1
    identities.append({
        "id": account_id,
        "name": account_id,
        "type": "User",
        "description": "MySQL account",
        "created_on": now,
        "is_active": is_active,
        "attributes": {
            "email": synth_email(account_id, dburl),
            "first_name": user or "NA",
            "last_name": "NA",
            "username": user,
            "host": host,
            "account_locked": account_locked,
            "password_expired": password_expired,
        },
    })

identity_ids = {identity["id"] for identity in identities}

# One group per role, members inverted from the edge list. A member that is itself
# a role is dropped: Resource Manager resolves members against identity ids, and a
# nested role is not an identity, so keeping it would dangle.
members_by_role = {}
nested = 0
for role, member in read_tsv(os.environ["ROLES_TSV"], 2):
    if member in identity_ids:
        members_by_role.setdefault(role, set()).add(member)
    else:
        nested += 1
        members_by_role.setdefault(role, set())

groups = []
for role in sorted(role_ids):
    groups.append({
        "id": role,
        "name": role,
        "type": "User group",
        "description": "MySQL role",
        "created_on": now,
        "is_active": True,
        "members": sorted(members_by_role.get(role, set())),
        "attributes": {"role": role},
    })

details = (
    f"MySQL scan completed on {os.environ['SERVER_VERSION']}. "
    f"Accounts: {len(identities)} ({locked} locked or expired), Roles: {len(groups)}"
)
if not roles_supported:
    details += ". Roles unavailable on this server, so no groups were reported"
if nested:
    details += f". Nested role grants skipped: {nested}"

payload = {
    "data": {
        "identities": identities,
        "groups": groups,
        "permissions": [],
        "permission_mapping": [],
    },
    "metadata": {
        "resource_id": dburl,
        "resource_type": "MySQL",
        "scan_time": now,
        "scan_details": details,
        "scan_errors": "",
        "attribute_resolution": {
            "group_membership": "id",
            "permission_mapping": "id",
        },
    },
}

with open(os.environ["OUT_JSON"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)

print(details)
PYEOF
rc=$?
[ "$rc" -eq 0 ] || die "failed to assemble the scan JSON (python exit ${rc})"

# ------------------------------------------------------------------------------
# Validate before publishing: writing straight to OUTPUT_PATH would let a
# half-formed payload reach the broker.
# ------------------------------------------------------------------------------
[ -s "$SCAN_JSON" ] || die "scan produced no output"

if ! python3 - "$SCAN_JSON" <<'PYEOF' >&2
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

data = payload["data"]
for key in ("identities", "groups", "permissions", "permission_mapping"):
    if not isinstance(data[key], list):
        raise SystemExit(f"data.{key} is not a list")
if not payload["metadata"]["resource_type"]:
    raise SystemExit("metadata.resource_type is empty")

# Every member must resolve to an identity id, or the platform silently drops the
# membership at import.
ids = {identity["id"] for identity in data["identities"]}
dangling = {m for group in data["groups"] for m in group["members"]} - ids
if dangling:
    raise SystemExit(f"{len(dangling)} group member(s) match no identity id, e.g. {sorted(dangling)[:3]}")

identity_count = len(data["identities"])
group_count = len(data["groups"])
print(f"validated: {identity_count} identities, {group_count} groups")
PYEOF
then
  die "assembled scan JSON failed validation"
fi

cat "$SCAN_JSON" > "$OUTPUT_PATH" || die "cannot write scan output to ${OUTPUT_PATH}"
SCAN_COMPLETED=true
info "scan written to ${OUTPUT_PATH} ($(wc -c < "$OUTPUT_PATH" | tr -d ' ') bytes)"
