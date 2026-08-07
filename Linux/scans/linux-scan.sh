#!/bin/bash
# ==============================================================================
# Britive Linux scan: local accounts and groups -> Resource Manager JSON
# ==============================================================================
# SSHes to a Linux host from the Bridge broker, reads the local user and group
# databases, and writes the Resource Manager scan payload. READ ONLY: it runs
# `getent` and reads nothing else.
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  (required) where to write the JSON
#
# ------------------------------------------------------------------------------
# RESOURCE ATTRIBUTES
# ------------------------------------------------------------------------------
#   Attribute             | Arrives as                     | Meaning
#   ----------------------|--------------------------------|-----------------------
#   HOSTNAME              | RESOURCE_HOSTNAME              | host to scan
#   PROVISION_USER        | RESOURCE_PROVISION_USER        | SSH login for the scan
#   PROVISION_KEY_LOCATION| RESOURCE_PROVISION_KEY_LOCATION| OPTIONAL path to its
#                         |                                | private key on the
#                         |                                | broker. Defaults to
#                         |                                | /home/bridge/.ssh/id_ed25519
#
# PROVISION_KEY_LOCATION is a PATH, not the key material -- the same convention the
# linux_tempuser checkout scripts use, and it defaults to the same place: the image
# writes the broker key to /home/bridge/.ssh/id_ed25519 from Secrets Manager at
# startup. The Linux resource does not set this attribute, so the default is the
# normal path.
#
# The scan needs NO sudo: getent reads /etc/passwd and /etc/group, both
# world-readable. Shadow entries are never touched.
#
# Optional env vars:
#   SSH_PORT      - default 22
#   MIN_UID       - lowest UID reported as an identity (default: 1000, the
#                   conventional start of human accounts on Debian/RHEL)
#   INCLUDE_ROOT  - "true" to also report root (uid 0). Default false.
#   SSH_TIMEOUT   - connect timeout, seconds (default: 15)
#
# ------------------------------------------------------------------------------
# WHAT MAPS ONTO WHAT
# ------------------------------------------------------------------------------
#   data.identities   one per local account at or above MIN_UID, id = username
#   data.groups       one per local group, members = SECONDARY members plus every
#                     account whose PRIMARY group it is
#   data.permissions  empty -- a POSIX account has no separate permission object
#   data.permission_mapping  empty -- membership lives in groups.members
#
# The primary-group merge is the part worth knowing. /etc/group lists only
# SECONDARY members; an account's primary group is a GID on its passwd row and
# appears nowhere in /etc/group. A scan that reported /etc/group verbatim would
# show "developers" as empty even though every developer has it as their login
# group. Both sources are combined here.
#
# System accounts below MIN_UID are excluded on purpose: daemon, bin, sshd and
# friends are not identities anyone checks out, and importing them would put
# dozens of unusable principals in the platform.
# ==============================================================================

set -uo pipefail

if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
  printf 'ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH is not set; cannot write scan output.\n' >&2
  exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"
mkdir -p "$(dirname "$OUTPUT_PATH")" \
  || { printf 'ERROR: cannot create output directory for %s\n' "$OUTPUT_PATH" >&2; exit 1; }

LOG_TAG="linux-scan"
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
TARGET_HOST="${TARGET_HOST:-${RESOURCE_HOSTNAME:-}}"
PROVISION_USER="${PROVISION_USER:-${RESOURCE_PROVISION_USER:-}}"
# Defaults to where the image writes the broker key from Secrets Manager, which is
# also what linux_tempuser_checkout.sh defaults to. The attribute is optional and
# the Linux resource does not currently set it.
PROVISION_KEY_LOCATION="${PROVISION_KEY_LOCATION:-${RESOURCE_PROVISION_KEY_LOCATION:-/home/bridge/.ssh/id_ed25519}}"
SSH_PORT="${SSH_PORT:-22}"
MIN_UID="${MIN_UID:-1000}"
INCLUDE_ROOT="${INCLUDE_ROOT:-false}"
SSH_TIMEOUT="${SSH_TIMEOUT:-15}"

[ -n "$TARGET_HOST" ] \
  || die "no host: set the resource's HOSTNAME attribute (arrives as RESOURCE_HOSTNAME), or TARGET_HOST when running by hand"
[ -n "$PROVISION_USER" ] \
  || die "no SSH login: set the resource's PROVISION_USER attribute (arrives as RESOURCE_PROVISION_USER)"

for cmd in ssh python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "broker is missing required command: ${cmd}"
done

# The key is a path on the broker. Check it before connecting: ssh's own failure
# for a missing identity file is "Permission denied (publickey)", which reads like
# an authorization problem on the target rather than a missing file here.
[ -r "$PROVISION_KEY_LOCATION" ] \
  || die "SSH key '${PROVISION_KEY_LOCATION}' is not readable on the broker. That path is the default; set the resource's PROVISION_KEY_LOCATION attribute to override it. If the image writes the key from Secrets Manager, confirm BrokerSSHPrivateKey is set on the stack and the entrypoint ran"

info "scan target ${PROVISION_USER}@${TARGET_HOST}:${SSH_PORT}, output ${OUTPUT_PATH}"

TMP_DIR="$(mktemp -d)" || die "mktemp -d failed (no writable TMPDIR?)"
chmod 700 "$TMP_DIR"

# ------------------------------------------------------------------------------
# Resolve the host before connecting. The broker's VPC often cannot resolve
# private/internal names, and ssh's failure for that is indistinguishable at a
# glance from a refused connection.
# ------------------------------------------------------------------------------
python3 -c 'import socket, sys; socket.getaddrinfo(sys.argv[1], int(sys.argv[2]))' \
    "$TARGET_HOST" "$SSH_PORT" 2>/dev/null \
  || die "host '${TARGET_HOST}' does not resolve from the broker -- use an address or a name this VPC can resolve"

# StrictHostKeyChecking=no with a null known_hosts: the broker scans hosts it has
# never seen and there is no key distribution here, so pinning would fail every
# first scan. The connection is still encrypted; it is the host identity that is
# unverified.
ssh_run() {
  ssh -i "$PROVISION_KEY_LOCATION" \
      -p "$SSH_PORT" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout="$SSH_TIMEOUT" \
      "${PROVISION_USER}@${TARGET_HOST}" \
      "$1"
}

info "connecting"
REMOTE_OS="$(ssh_run 'uname -sr' 2>"${TMP_DIR}/connect.err")" \
  || die "SSH to ${PROVISION_USER}@${TARGET_HOST}:${SSH_PORT} failed: $(tr '\n' ' ' < "${TMP_DIR}/connect.err" | cut -c1-180)"
info "remote os ${REMOTE_OS}"

# getent, not `cat /etc/passwd`: it also returns accounts from SSSD/LDAP/AD via
# nsswitch, which is exactly the population that matters on a domain-joined host.
PASSWD_TXT="${TMP_DIR}/passwd.txt"
GROUP_TXT="${TMP_DIR}/group.txt"

ssh_run 'getent passwd' > "$PASSWD_TXT" 2>"${TMP_DIR}/passwd.err" \
  || die "cannot read the passwd database on ${TARGET_HOST}: $(tr '\n' ' ' < "${TMP_DIR}/passwd.err" | cut -c1-180)"
ssh_run 'getent group' > "$GROUP_TXT" 2>"${TMP_DIR}/group.err" \
  || die "cannot read the group database on ${TARGET_HOST}: $(tr '\n' ' ' < "${TMP_DIR}/group.err" | cut -c1-180)"

[ -s "$PASSWD_TXT" ] || die "the passwd database on ${TARGET_HOST} came back empty"

info "passwd lines $(wc -l < "$PASSWD_TXT" | tr -d ' '), group lines $(wc -l < "$GROUP_TXT" | tr -d ' ')"

# ------------------------------------------------------------------------------
# Assemble the payload.
# ------------------------------------------------------------------------------
SCAN_JSON="${TMP_DIR}/scan.json"

TARGET_HOST="$TARGET_HOST" \
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
PASSWD_TXT="$PASSWD_TXT" \
GROUP_TXT="$GROUP_TXT" \
MIN_UID="$MIN_UID" \
INCLUDE_ROOT="$INCLUDE_ROOT" \
REMOTE_OS="$REMOTE_OS" \
OUT_JSON="$SCAN_JSON" \
python3 <<'PYEOF'
import json
import os
import re

# A locked account has ! or * in the shadow hash, which we never read. What is
# visible here is the shell: nologin/false means the account cannot log in, which
# is the part that matters for access.
NOLOGIN_SHELLS = {"/sbin/nologin", "/usr/sbin/nologin", "/bin/false", "/usr/bin/false", ""}

target_host = os.environ["TARGET_HOST"]
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

min_uid = int(os.environ["MIN_UID"])
include_root = os.environ["INCLUDE_ROOT"] == "true"


def read_colon(path, width):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split(":")
            if len(fields) < width:
                continue
            rows.append(fields)
    return rows


identities = []
primary_gid = {}          # username -> primary GID
nologin = 0
skipped_system = 0

for fields in read_colon(os.environ["PASSWD_TXT"], 7):
    name, _pw, uid_s, gid_s, gecos, home, shell = fields[:7]
    try:
        uid, gid = int(uid_s), int(gid_s)
    except ValueError:
        continue

    if uid == 0:
        if not include_root:
            skipped_system += 1
            continue
    elif uid < min_uid:
        skipped_system += 1
        continue

    can_login = shell not in NOLOGIN_SHELLS
    if not can_login:
        nologin += 1

    primary_gid[name] = gid
    identities.append({
        "id": name,
        "name": name,
        "type": "User",
        "description": "Linux local account",
        "created_on": now,
        "is_active": can_login,
        "attributes": {
            # GECOS holds a display name on many systems; use it when present.
            "email": synth_email(name, target_host),
            "first_name": (gecos.split(",")[0].split()[0] if gecos.split(",")[0].strip() else name) or "NA",
            "last_name": (" ".join(gecos.split(",")[0].split()[1:]) or "NA"),
            "username": name,
            "uid": uid_s,
            "gid": gid_s,
            "gecos": gecos,
            "home": home,
            "shell": shell,
        },
    })

identity_ids = {identity["id"] for identity in identities}

# /etc/group carries only SECONDARY members. Fold in every account whose PRIMARY
# group this is, or a login group looks empty when it is the most-used one.
groups = []
for fields in read_colon(os.environ["GROUP_TXT"], 4):
    name, _pw, gid_s, members_s = fields[:4]
    try:
        gid = int(gid_s)
    except ValueError:
        continue

    members = {m for m in members_s.split(",") if m and m in identity_ids}
    members |= {user for user, user_gid in primary_gid.items() if user_gid == gid}

    # A group with no reportable members is dropped: it would import as an empty
    # principal with nothing to grant, and system groups are the bulk of them.
    if not members:
        continue

    groups.append({
        "id": name,
        "name": name,
        "type": "User group",
        "description": "Linux local group",
        "created_on": now,
        "is_active": True,
        "members": sorted(members),
        "attributes": {"group_name": name, "gid": gid_s},
    })

groups.sort(key=lambda g: g["id"])

details = (
    f"Linux scan completed on {target_host} ({os.environ['REMOTE_OS']}). "
    f"Accounts: {len(identities)} ({nologin} without a login shell), "
    f"Groups: {len(groups)}, "
    f"System accounts below uid {min_uid} skipped: {skipped_system}"
)

payload = {
    "data": {
        "identities": identities,
        "groups": groups,
        "permissions": [],
        "permission_mapping": [],
    },
    "metadata": {
        "resource_id": target_host,
        "resource_type": "Linux",
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
