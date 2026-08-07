#!/bin/bash
# ==============================================================================
# Britive AD scan: users, groups and memberships -> Resource Manager JSON
# ==============================================================================
# Adapted from the upstream access-broker-examples scans/ad-scan.sh (itself a
# Linux port of ad-scan.ps1 / ad-scan_2.ps1) to fit this repo's conventions:
# LDAPS by default, credentials from Secrets Manager, and the shared
# lib/ad_common.sh helpers.
#
# Emits the Britive Resource Manager schema with resource_type=ActiveDirectory:
#   data.identities         one per AD user, id = sAMAccountName
#   data.groups             one per AD group, id = sAMAccountName, with members
#   data.permissions        empty — AD has no separate permission objects
#   data.permission_mapping empty — user-to-group lives in groups.members
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  (required) where to write the JSON
#
# ------------------------------------------------------------------------------
# RESOURCE ATTRIBUTES
# ------------------------------------------------------------------------------
# A scan runs against a resource, and the broker injects that resource's
# attributes prefixed with RESOURCE_. The ADDomain resource defines these six:
#
#   Attribute | Arrives as         | Used as     | Notes
#   ----------|--------------------|-------------|--------------------------------
#   HOST      | RESOURCE_HOST      | AD_HOST     | domain controller (REQUIRED)
#   SECRET    | RESOURCE_SECRET    | AD_SECRET   | Secrets Manager id holding
#             |                    |             | {bind_dn|username, password}
#   REGION    | RESOURCE_REGION    | AWS_REGION  | ad_init defaults it to us-west-2
#   CA_CERT   | RESOURCE_CA_CERT   | AD_CA_CERT  | LDAPS trust bundle; ad_init
#             |                    |             | defaults it to the system bundle
#   BASE_DN   | RESOURCE_BASE_DN   | AD_BASE_DN  | search base; discovered from
#             |                    |             | RootDSE when empty
#   USER_OU   | RESOURCE_USER_OU   | AD_USER_OU  | accepted, NOT used to scope the
#             |                    |             | scan -- see the note at the mapping
#
# Setting an AD_* var directly overrides the resource attribute, so this script
# stays runnable by hand for testing. RESOURCE_USER + RESOURCE_PASSWORD are also
# still honoured as a legacy bind path when SECRET is absent.
#
# Other connection env vars: see lib/ad_common.sh (AD_PORT, AD_TLS_REQCERT,
# AD_TIMEOUT, AD_PAGE_SIZE).
#
# ------------------------------------------------------------------------------
# CHANGED FROM THE UPSTREAM SHELL SCRIPT
# ------------------------------------------------------------------------------
#   * LDAPS, always. Upstream defaulted to LDAP_PROTOCOL=ldap on port 389 with a
#     simple bind. A DC configured to require LDAP signing — the default on a
#     hardened domain — rejects that outright with
#     "Strong(er) authentication required (8)", so the scan could never bind. It
#     also sent the bind password in cleartext.
#   * Credentials come from Secrets Manager when AD_SECRET is set, instead of
#     requiring the password as a plaintext resource parameter.
#   * Uses the shared library, so the scan and the checkout/checkin scripts share
#     one LDAP/TLS/credential path rather than two that can drift.
#
# ------------------------------------------------------------------------------
# MEMBERSHIP IS INVERTED FROM EACH USER'S memberOf
# ------------------------------------------------------------------------------
# Kept from upstream, and the reason this beats both PowerShell variants:
#   * ad-scan_2.ps1 read each group's `member` attribute in bulk, which AD
#     truncates at MaxValRange (~5000) with NO error — members silently vanish.
#   * ad-scan.ps1 avoided that with a Get-ADGroupMember call per group, at the
#     cost of one query per group.
# Reading `memberOf` from the user side hits neither: a user is rarely in more
# than a handful of groups, and it is two paged queries total.
#
# The trade-off, unchanged from all three: an account's PRIMARY group (normally
# Domain Users) lives in primaryGroupID, not in the group's member list, so it
# does not appear here.
# ==============================================================================

set -euo pipefail

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

# Locate the shared AD helper library. v2/ecr/Dockerfile bakes it into the
# Bridge image; AD_COMMON_LIB overrides the path for local testing.
AD_COMMON_LIB="${AD_COMMON_LIB:-/opt/britive-broker/lib/ad_common.sh}"
if [ ! -r "$AD_COMMON_LIB" ]; then
  printf 'ERROR: AD helper library not readable at %s\n' "$AD_COMMON_LIB" >&2
  exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/ad_common.sh
. "$AD_COMMON_LIB"

AD_LOG_TAG="ad-scan"

# ------------------------------------------------------------------------------
# Every exit path must leave valid JSON at OUTPUT_PATH — the broker parses that
# file to learn what happened, and a missing or truncated file reports as an
# opaque failure with no reason attached.
# ------------------------------------------------------------------------------
SCAN_COMPLETED=false

# write_scan_error <message> — minimal well-formed payload carrying the reason.
# python does the JSON encoding so a message containing quotes, backslashes or
# newlines cannot produce a malformed file (the upstream sed-based escaping
# mangled backslashes).
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

# Override the library's die() so every failure — including those raised inside
# library functions — records the reason for the broker before exiting. Bash
# resolves function names at call time, so the library's internal `die` calls
# reach this definition.
die() {
  error "$*"
  write_scan_error "$*"
  exit 1
}

# Backstop for a failure that never reaches die(): a `set -e` abort, or a signal.
scan_exit_trap() {
  local rc=$?
  if [ "$SCAN_COMPLETED" != "true" ] && [ ! -s "$OUTPUT_PATH" ]; then
    write_scan_error "scan aborted unexpectedly (exit ${rc}); see the broker log for the failing step"
  fi
  ad_cleanup
}
trap scan_exit_trap EXIT INT TERM

# ------------------------------------------------------------------------------
# Resource attributes -> the AD_* names the library reads.
# ------------------------------------------------------------------------------
# The scan runs against a RESOURCE, so its attributes arrive prefixed:
# RESOURCE_HOST, RESOURCE_SECRET, and so on. The helper handles that, and an
# explicitly set AD_* value still wins so this stays runnable by hand.
#
# AD_USER_OU is mapped but NOT used to scope this scan. Restricting the search to
# it would be wrong: group objects normally live in a sibling OU (OU=Groups), so a
# scan bounded by the user OU returns users with no groups to map them to.
# The broker injects the resource's attributes with a RESOURCE_ prefix; the shared
# library reads the AD_* names. Assign them across, plainly. Kept in the script
# rather than the library because Britive re-fetches this script on every run,
# while the library only changes when the image is rebuilt.
#
# AD_TARGET_USER and AD_NEW_PASSWORD are NOT here: the broker passes those under
# their own names already (AD_NEW_PASSWORD arrives encrypted, which is why it does
# not appear in the request log).
#
# An AD_* value set directly wins, so the script stays runnable by hand. Unset
# attributes are left empty on purpose -- ad_init owns the defaults.
AD_HOST="${AD_HOST:-${RESOURCE_HOST:-}}"
AD_BASE_DN="${AD_BASE_DN:-${RESOURCE_BASE_DN:-}}"
AD_SECRET="${AD_SECRET:-${RESOURCE_SECRET:-}}"
AWS_REGION="${AWS_REGION:-${RESOURCE_REGION:-}}"
AD_CA_CERT="${AD_CA_CERT:-${RESOURCE_CA_CERT:-}}"
AD_USER_OU="${AD_USER_OU:-${RESOURCE_USER_OU:-}}"
export AD_HOST AD_BASE_DN AD_SECRET AWS_REGION AD_CA_CERT AD_USER_OU

# Legacy direct-credential path from the upstream script, kept so an older
# resource definition still binds. AD_SECRET wins when both are present.
# Note RESOURCE_USER is the bind account and is unrelated to RESOURCE_USER_OU.
if [ -z "$AD_SECRET" ] && [ -n "${RESOURCE_USER:-}" ]; then
  AD_BIND_DN="${AD_BIND_DN:-$RESOURCE_USER}"
  AD_BIND_PASSWORD="${AD_BIND_PASSWORD:-${RESOURCE_PASSWORD:-}}"
  warn "using RESOURCE_USER/RESOURCE_PASSWORD; prefer the SECRET attribute so no plaintext password is a resource parameter"
fi

[ -n "$AD_HOST" ] || die "no domain controller configured: set the resource's HOST attribute (arrives as RESOURCE_HOST), or AD_HOST when running by hand"

info "scan target ${AD_HOST}, output ${OUTPUT_PATH}"

# Validates the toolchain, resolves credentials, enforces LDAPS, proves the bind,
# and discovers AD_BASE_DN from RootDSE when it was not supplied.
ad_init

# ------------------------------------------------------------------------------
# Two paged queries. Any failure is fatal: a partial scan would look to the
# platform like a directory that genuinely shrank, and Britive would deprovision
# the identities that "disappeared".
# ------------------------------------------------------------------------------
USERS_LDIF="${AD_TMP_DIR}/users.ldif"
GROUPS_LDIF="${AD_TMP_DIR}/groups.ldif"

info "querying users (page size ${AD_PAGE_SIZE})"
ad_search_paged "$AD_BASE_DN" sub "(&(objectCategory=person)(objectClass=user))" \
    sAMAccountName mail givenName sn userPrincipalName userAccountControl memberOf \
    > "$USERS_LDIF" 2>"${AD_TMP_DIR}/users.err" \
  || die "user query failed: $(tr '\n' ' ' < "${AD_TMP_DIR}/users.err")"

info "querying groups"
ad_search_paged "$AD_BASE_DN" sub "(objectClass=group)" \
    sAMAccountName cn name \
    > "$GROUPS_LDIF" 2>"${AD_TMP_DIR}/groups.err" \
  || die "group query failed: $(tr '\n' ' ' < "${AD_TMP_DIR}/groups.err")"

info "users LDIF $(wc -c < "$USERS_LDIF" | tr -d ' ') bytes, groups LDIF $(wc -c < "$GROUPS_LDIF" | tr -d ' ') bytes"

# ------------------------------------------------------------------------------
# Assemble the payload. python stdlib only — no pip dependency on the broker.
# ------------------------------------------------------------------------------
SCAN_JSON="${AD_TMP_DIR}/scan.json"

# The env-var prefixes below must stay directly attached to `python3` with
# unbroken line continuations — a comment between them would end the command and
# the program would run with none of these set.
# shellcheck disable=SC2016  # the $ inside the program is a regex anchor, not a shell expansion
BASE_DN="$AD_BASE_DN" \
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
USERS_LDIF="$USERS_LDIF" \
GROUPS_LDIF="$GROUPS_LDIF" \
OUT_JSON="$SCAN_JSON" \
python3 -c '
import base64
import json
import os
import re

UAC_ACCOUNTDISABLE = 0x2
MAX_GROUP_NAME = 255


def parse_ldif(path):
    """Yield one dict per LDIF entry, decoding base64 (`attr::`) values.

    ldapsearch ran with `-o ldif-wrap=no`, so every attribute is on a single
    line and no continuation handling is needed.
    """
    entries, current = [], None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\r\n")
            if not line:
                if current is not None:
                    entries.append(current)
                    current = None
                continue
            if line.startswith("#"):
                continue
            match = re.match(r"^([^:]+)(::?)[ ]?(.*)$", line)
            if not match:
                continue
            attr, separator, value = match.groups()
            if separator == "::":
                try:
                    value = base64.b64decode(value).decode("utf-8", "replace")
                except Exception:
                    pass
            if current is None:
                current = {}
            current.setdefault(attr, []).append(value)
    if current is not None:
        entries.append(current)
    return entries


def first(entry, key, default=""):
    values = entry.get(key)
    return values[0] if values else default


base_dn = os.environ["BASE_DN"]
now = os.environ["NOW"]
domain = ".".join(re.findall(r"DC=([^,]+)", base_dn, re.I)) or "ad.local"

users = parse_ldif(os.environ["USERS_LDIF"])
groups = parse_ldif(os.environ["GROUPS_LDIF"])

# group DN (lowercased) -> set of member sAMAccountNames, inverted from memberOf
membership = {}
identities = []
skipped_users = 0

for user in users:
    sam = first(user, "sAMAccountName")
    if not sam:
        # Contacts and some system objects match the user filter but have no
        # sAMAccountName; without one there is no id to key an identity on.
        skipped_users += 1
        continue

    try:
        disabled = bool(int(first(user, "userAccountControl", "0")) & UAC_ACCOUNTDISABLE)
    except ValueError:
        disabled = False

    identities.append({
        "id": sam,
        "name": sam,
        "type": "User",
        "description": "Active Directory user",
        "created_on": now,
        "is_active": not disabled,
        "attributes": {
            # email must be non-null for the platform; synthesise one when the
            # directory has no mail attribute.
            "email": first(user, "mail") or f"{sam}@{domain}",
            "first_name": first(user, "givenName") or "NA",
            "last_name": first(user, "sn") or "NA",
            "samaccountname": sam,
            "user_principal_name": first(user, "userPrincipalName"),
            "distinguished_name": first(user, "dn"),
        },
    })

    for group_dn in user.get("memberOf", []):
        membership.setdefault(group_dn.lower(), set()).add(sam)

groups_out = []
cnf_skipped = 0
empty_groups = 0

for group in groups:
    dn = first(group, "dn")
    name = first(group, "cn") or first(group, "name") or first(group, "sAMAccountName")

    # Replication-conflict objects carry a CNF: marker and duplicate a real
    # group; importing them creates phantom groups in the platform.
    if "CNF:" in dn or "CNF:" in name:
        cnf_skipped += 1
        continue

    name = re.sub(r"[\r\n\t]", " ", name).strip()[:MAX_GROUP_NAME]
    group_sam = first(group, "sAMAccountName") or name
    members = sorted(membership.get(dn.lower(), set()))
    if not members:
        empty_groups += 1

    groups_out.append({
        # sAMAccountName is unique per domain; the display name is not, so using
        # it as the id (as both PowerShell variants did) risks collisions.
        "id": group_sam,
        "name": name,
        "type": "User group",
        "description": "Active Directory group",
        "created_on": now,
        "is_active": True,
        "members": members,
        "attributes": {"samaccountname": group_sam, "distinguished_name": dn},
    })

details = (
    f"AD scan completed. Users: {len(identities)}, Groups: {len(groups_out)}, "
    f"Empty groups: {empty_groups}, CNF skipped: {cnf_skipped}, "
    f"Users without sAMAccountName skipped: {skipped_users}"
)

payload = {
    "data": {
        "identities": identities,
        "groups": groups_out,
        "permissions": [],
        "permission_mapping": [],
    },
    "metadata": {
        "resource_id": base_dn,
        "resource_type": "ActiveDirectory",
        "scan_time": now,
        "scan_details": details,
        "scan_errors": "",
        "attribute_resolution": {
            # groups.members holds sAMAccountNames, matching identity.id
            "group_membership": "id",
            "permission_mapping": "id",
        },
    },
}

with open(os.environ["OUT_JSON"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)

print(details)
' >&2 || die "failed to assemble the scan JSON"

# ------------------------------------------------------------------------------
# Validate before publishing. Writing straight to OUTPUT_PATH would let a
# half-formed payload reach the broker.
# ------------------------------------------------------------------------------
[ -s "$SCAN_JSON" ] || die "scan produced no output"

python3 -c '
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

# Every member must resolve to an identity id, or the platform silently drops
# the membership at import.
ids = {identity["id"] for identity in data["identities"]}
dangling = {member for group in data["groups"] for member in group["members"]} - ids
if dangling:
    raise SystemExit(f"{len(dangling)} group member(s) match no identity id, e.g. {sorted(dangling)[:3]}")

# Counts are bound to names first: this program is inside a single-quoted shell
# -c string, so a backslash-escaped quote would reach python verbatim and a
# nested double quote inside an f-string expression is a SyntaxError.
identity_count = len(data["identities"])
group_count = len(data["groups"])
print(f"validated: {identity_count} identities, {group_count} groups")
' "$SCAN_JSON" >&2 \
  || die "assembled scan JSON failed validation"

cat "$SCAN_JSON" > "$OUTPUT_PATH" || die "cannot write scan output to ${OUTPUT_PATH}"
SCAN_COMPLETED=true

info "scan written to ${OUTPUT_PATH} ($(wc -c < "$OUTPUT_PATH" | tr -d ' ') bytes)"
