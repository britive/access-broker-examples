#!/bin/bash
# ==============================================================================
# Britive MSSQL scan: server logins and server roles -> Resource Manager JSON
# ==============================================================================
# Enumerates SQL Server logins and server-level roles from the Bridge broker and
# writes the Resource Manager scan payload. READ ONLY: nothing but SELECTs.
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  (required) where to write the JSON
#
# ------------------------------------------------------------------------------
# RESOURCE ATTRIBUTES
# ------------------------------------------------------------------------------
#   Attribute        | Arrives as                | Meaning
#   -----------------|---------------------------|----------------------------
#   DBURL            | RESOURCE_DBURL            | SQL Server endpoint hostname
#   ADMIN_USER       | RESOURCE_ADMIN_USER       | admin login (optional; falls back
#                    |                           | to the secret's username field)
#   AWS_SECRET_NAME  | RESOURCE_AWS_SECRET_NAME  | Secrets Manager id holding
#                    |                           | {username, password} for admin
#
# Optional env vars:
#   DB_PORT     - SQL Server port (default: 1433)
#   DB_NAME     - database to connect to (default: master; the scan reads
#                 server-level catalog views, which live there)
#   AWS_REGION  - Secrets Manager region (default: us-west-2)
#   DB_CA_CERT  - CA bundle for certificate verification. Without it the
#                 connection is encrypted but the chain is NOT verified (-C).
#
# ------------------------------------------------------------------------------
# WHAT MAPS ONTO WHAT
# ------------------------------------------------------------------------------
#   data.identities   one per SERVER LOGIN (sys.server_principals types S/U/G)
#   data.groups       one per SERVER ROLE (type R), members from
#                     sys.server_role_members
#   data.permissions  empty -- see below
#   data.permission_mapping  empty -- role membership lives in groups.members
#
# SERVER level, not database level, and that is a deliberate scope choice. A login
# is server-wide; a database *user* is a per-database object mapped to a login, and
# there is one set of them per database. Reporting database users would produce
# duplicate-looking identities with no stable id, so the login is the identity and
# server roles are the groups.
#
# Privileges are not enumerated: sys.server_permissions plus every database's
# object-level grants is enormous, changes on every DDL, and server roles are the
# useful unit of access.
#
# ------------------------------------------------------------------------------
# NOTE ON THE CLIENT
# ------------------------------------------------------------------------------
# Uses go-sqlcmd (`sqlcmd`), which the image installs instead of Microsoft's
# mssql-tools -- those are glibc + amd64 only and will not run on this musl/ARM64
# image. Flags differ slightly from the Microsoft client: -C trusts the server
# certificate, and the password comes from SQLCMDPASSWORD rather than -P so it
# stays out of /proc/<pid>/cmdline.
# ==============================================================================

set -uo pipefail

if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
  printf 'ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH is not set; cannot write scan output.\n' >&2
  exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"
mkdir -p "$(dirname "$OUTPUT_PATH")" \
  || { printf 'ERROR: cannot create output directory for %s\n' "$OUTPUT_PATH" >&2; exit 1; }

LOG_TAG="mssql-scan"
TRACE=""

# INFO is buffered and the error prints FIRST: Britive keeps only about the first
# 250 characters of captured output. SCAN_VERBOSE=true restores live logging.
info() {
  if [ "${SCAN_VERBOSE:-false}" = "true" ]; then
    printf '%s [%s] INFO  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_TAG" "$1" >&2
  else
    TRACE="${TRACE}${1}; "
  fi
}

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
DB_PORT="${DB_PORT:-1433}"
DB_NAME="${DB_NAME:-master}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DB_CA_CERT="${DB_CA_CERT:-}"
DB_ADMIN_USER_ATTR="${DB_ADMIN_USER:-${RESOURCE_ADMIN_USER:-}}"

[ -n "$DBURL" ] \
  || die "no database endpoint: set the resource's DBURL attribute (arrives as RESOURCE_DBURL), or DBURL when running by hand"
[ -n "$SECRET_NAME" ] \
  || die "no admin credential: set the resource's AWS_SECRET_NAME attribute (arrives as RESOURCE_AWS_SECRET_NAME)"

for cmd in sqlcmd aws jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "broker is missing required command: ${cmd}"
done

info "scan target ${DBURL}:${DB_PORT}, output ${OUTPUT_PATH}"

TMP_DIR="$(mktemp -d)" || die "mktemp -d failed (no writable TMPDIR?)"
chmod 700 "$TMP_DIR"

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

# SQLCMDPASSWORD rather than -P: an argument would sit in /proc/<pid>/cmdline for
# the life of the call, readable by anything in the container.
export SQLCMDPASSWORD="$DB_ADMIN_PASSWORD"
unset DB_ADMIN_PASSWORD

TLS_ARGS=(-N)                       # -N: encrypt the connection
if [ -n "$DB_CA_CERT" ]; then
  export SSL_CERT_FILE="$DB_CA_CERT"
else
  TLS_ARGS+=(-C)                    # -C: trust the server certificate unverified
fi

# mssql_query <sql> — one record per line, fields separated by a US (0x1f) unit
# separator. Not a tab or comma: a login name may legally contain either, and a
# split on the wrong character silently corrupts identity ids.
SEP=$'\x1f'
mssql_query() {
  sqlcmd -S "tcp:${DBURL},${DB_PORT}" -U "$DB_ADMIN_USER" -d "$DB_NAME" \
    "${TLS_ARGS[@]}" -l 15 -h -1 -W -s "$SEP" -Q "SET NOCOUNT ON; $1"
}

info "connecting"
SERVER_VERSION="$(mssql_query "SELECT CONVERT(varchar(200), SERVERPROPERTY('ProductVersion'));" 2>"${TMP_DIR}/connect.err" | head -1)" \
  || die "cannot connect to ${DBURL}:${DB_PORT} as '${DB_ADMIN_USER}': $(tr '\n' ' ' < "${TMP_DIR}/connect.err" | cut -c1-200)"
[ -n "$SERVER_VERSION" ] \
  || die "connected to ${DBURL}:${DB_PORT} but got no version back: $(tr '\n' ' ' < "${TMP_DIR}/connect.err" | cut -c1-200)"
info "server version ${SERVER_VERSION}"

# ------------------------------------------------------------------------------
# Logins. is_disabled is on sys.sql_logins only (SQL logins); Windows principals
# have no such column, hence the LEFT JOIN and the ISNULL default of enabled.
# ------------------------------------------------------------------------------
LOGINS_TSV="${TMP_DIR}/logins.tsv"
mssql_query "
  SELECT p.name, p.type, p.type_desc, ISNULL(CONVERT(int, l.is_disabled), 0)
    FROM sys.server_principals AS p
    LEFT JOIN sys.sql_logins  AS l ON l.principal_id = p.principal_id
   WHERE p.type IN ('S','U','G')
     AND p.name NOT LIKE '##%'
   ORDER BY p.name;" > "$LOGINS_TSV" 2>"${TMP_DIR}/logins.err" \
  || die "cannot read sys.server_principals (the admin needs VIEW ANY DEFINITION or sysadmin): $(tr '\n' ' ' < "${TMP_DIR}/logins.err" | cut -c1-200)"

# ------------------------------------------------------------------------------
# Server roles and their members.
# ------------------------------------------------------------------------------
ROLES_TSV="${TMP_DIR}/roles.tsv"
mssql_query "
  SELECT r.name, ISNULL(m.name, '')
    FROM sys.server_principals AS r
    LEFT JOIN sys.server_role_members AS rm ON rm.role_principal_id = r.principal_id
    LEFT JOIN sys.server_principals   AS m  ON m.principal_id = rm.member_principal_id
   WHERE r.type = 'R'
     AND r.name NOT LIKE '##%'
   ORDER BY r.name;" > "$ROLES_TSV" 2>"${TMP_DIR}/roles.err" \
  || die "cannot read sys.server_role_members: $(tr '\n' ' ' < "${TMP_DIR}/roles.err" | cut -c1-200)"

info "login rows $(wc -l < "$LOGINS_TSV" | tr -d ' '), role rows $(wc -l < "$ROLES_TSV" | tr -d ' ')"

# ------------------------------------------------------------------------------
# Assemble the payload.
# ------------------------------------------------------------------------------
SCAN_JSON="${TMP_DIR}/scan.json"

DBURL="$DBURL" \
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
LOGINS_TSV="$LOGINS_TSV" \
ROLES_TSV="$ROLES_TSV" \
SERVER_VERSION="$SERVER_VERSION" \
OUT_JSON="$SCAN_JSON" \
python3 <<'PYEOF'
import json
import os
import re

SEP = "\x1f"

TYPE_DESC = {
    "S": "SQL login",
    "U": "Windows login",
    "G": "Windows group",
}


def read_rows(path, width):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            fields = [f.strip() for f in line.split(SEP)]
            if len(fields) < width:
                continue
            rows.append(fields[:width])
    return rows


dburl = os.environ["DBURL"]
now = os.environ["NOW"]

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


identities = []
disabled = 0
seen = set()
for name, ptype, type_desc, is_disabled in read_rows(os.environ["LOGINS_TSV"], 4):
    if not name or name in seen:
        continue
    seen.add(name)
    # The LEFT JOIN yields 0 for Windows principals, which have no is_disabled.
    active = is_disabled != "1"
    if not active:
        disabled += 1
    identities.append({
        "id": name,
        "name": name,
        "type": "User",
        "description": TYPE_DESC.get(ptype, type_desc or "SQL Server login"),
        "created_on": now,
        "is_active": active,
        "attributes": {
            "email": synth_email(name, dburl),
            "first_name": name.split("\\")[-1] or "NA",
            "last_name": "NA",
            "login": name,
            "principal_type": ptype,
            "principal_type_desc": type_desc,
        },
    })

identity_ids = {identity["id"] for identity in identities}

# The role query LEFT JOINs members, so a role with no members still appears with
# an empty member field. Members outside identity_ids are dropped: Resource
# Manager resolves members against identity ids, and a nested role is not one.
members_by_role = {}
nested = 0
for role, member in read_rows(os.environ["ROLES_TSV"], 2):
    if not role:
        continue
    bucket = members_by_role.setdefault(role, set())
    if member:
        if member in identity_ids:
            bucket.add(member)
        else:
            nested += 1

groups = []
empty = 0
for role in sorted(members_by_role):
    members = sorted(members_by_role[role])
    if not members:
        empty += 1
    groups.append({
        "id": role,
        "name": role,
        "type": "User group",
        "description": "SQL Server server role",
        "created_on": now,
        "is_active": True,
        "members": members,
        "attributes": {"server_role": role},
    })

details = (
    f"MSSQL scan completed on {os.environ['SERVER_VERSION']}. "
    f"Logins: {len(identities)} ({disabled} disabled), "
    f"Server roles: {len(groups)} ({empty} empty)"
)
if nested:
    details += f". Nested role memberships skipped: {nested}"

payload = {
    "data": {
        "identities": identities,
        "groups": groups,
        "permissions": [],
        "permission_mapping": [],
    },
    "metadata": {
        "resource_id": dburl,
        "resource_type": "MSSQL",
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
