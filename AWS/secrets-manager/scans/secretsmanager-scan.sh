#!/bin/bash
# ==============================================================================
# Britive AWS Secrets Manager scan: secrets -> Resource Manager JSON
# ==============================================================================
# Enumerates the secrets in one AWS account + region and writes the Resource
# Manager scan payload. READ ONLY: ListSecrets only, never GetSecretValue.
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH  (required) where to write the JSON
#
# ------------------------------------------------------------------------------
# WHAT A "RESOURCE" AND AN "IDENTITY" ARE HERE
# ------------------------------------------------------------------------------
# One resource  = one AWS account + region scope.
# One identity  = one secret, keyed by its NAME.
#
# That is the shape Resource Manager already understands: a scan discovers
# accounts on a resource, and a rotation rotates a discovered account. A secret
# maps onto an account cleanly, so nothing has to be bent to fit.
#
# The id is the secret name, not the ARN. The platform stores it in
# t_resource_data_account.native_id, a short column that a full ARN overflows:
#
#   Data truncation: Data too long for column 'native_id' at row 1
#
# The name is the correct key regardless -- it is unique within one account and
# region, which is exactly the scope of one resource. The full ARN travels in the
# secret_arn attribute (a JSON column, so length is not a constraint there), and
# that is what a rotation targets.
#
# ------------------------------------------------------------------------------
# SECRET VALUES ARE NEVER READ
# ------------------------------------------------------------------------------
# This script calls ListSecrets and nothing else. It does not call
# GetSecretValue, and no secret value appears in the payload, the metadata or the
# logs.
#
# That is deliberate, not an oversight. The scan payload is uploaded to and
# stored by the Britive platform, and it is echoed into the broker log whenever
# validation fails. A value placed in it would be exposed in both places. The
# value stays in AWS; a rotation is what puts it under Britive's control, and it
# reads the value at rotation time under the ARN this scan recorded.
#
# ------------------------------------------------------------------------------
# RESOURCE ATTRIBUTES
# ------------------------------------------------------------------------------
# A scan runs against a resource, and the broker injects that resource's
# attributes with a RESOURCE_ prefix, UPPER-CASED:
#
#   Attribute          | Arrives as                  | Meaning
#   -------------------|-----------------------------|--------------------------
#   AWS_REGION         | RESOURCE_AWS_REGION         | region to enumerate
#   SECRET_PREFIX      | RESOURCE_SECRET_PREFIX      | name-prefix filter (opt)
#   SECRET_TAG_KEY     | RESOURCE_SECRET_TAG_KEY     | tag-key filter (opt)
#   SECRET_TAG_VALUE   | RESOURCE_SECRET_TAG_VALUE   | tag-value filter (opt)
#   GROUP_TAG_KEY      | RESOURCE_GROUP_TAG_KEY      | tag whose values become
#                      |                             | groups (default Environment)
#
# Setting the bare name directly overrides the attribute, so this stays runnable
# by hand for testing.
#
# Optional env var:
#   SECRET_ID_MAX_LENGTH  - cap on identity/group ids (default 50). A longer name
#                           is shortened deterministically to prefix + sha256
#                           fragment rather than truncated, so two secrets sharing
#                           a prefix keep distinct ids.
#
# The prefix and tag filters exist to bound the blast radius: an unfiltered scan
# of a shared account hands Resource Manager every secret in it, including ones
# owned by other teams.
#
# ------------------------------------------------------------------------------
# WHAT MAPS ONTO WHAT
# ------------------------------------------------------------------------------
#   data.identities   one per secret, id = secret name (ARN in secret_arn)
#   data.groups       one per distinct GROUP_TAG_KEY tag value, plus the synthetic
#                     rotation-enabled / rotation-disabled / service-owned groups
#   data.permissions  empty -- see below
#   data.permission_mapping  empty
#
# Resource policies are deliberately NOT enumerated: that is one GetResourcePolicy
# call per secret, most secrets have no policy at all, and Resource Manager
# consumes groups rather than raw IAM documents. Tags are already on the
# ListSecrets response, so grouping by them is free.
#
# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------
# The broker's task role needs:
#   secretsmanager:ListSecrets   (resource must be *; the API cannot be scoped)
#   sts:GetCallerIdentity        (implicitly allowed)
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

LOG_TAG="secretsmanager-scan"
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
# Resource attributes. Plain assignment, no name guessing: the broker prefixes
# and upper-cases, and that is the whole rule.
# ------------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-${RESOURCE_AWS_REGION:-}}"
SECRET_PREFIX="${SECRET_PREFIX:-${RESOURCE_SECRET_PREFIX:-}}"
SECRET_TAG_KEY="${SECRET_TAG_KEY:-${RESOURCE_SECRET_TAG_KEY:-}}"
SECRET_TAG_VALUE="${SECRET_TAG_VALUE:-${RESOURCE_SECRET_TAG_VALUE:-}}"
GROUP_TAG_KEY="${GROUP_TAG_KEY:-${RESOURCE_GROUP_TAG_KEY:-Environment}}"
# t_resource_data_account.native_id is a short column and a full ARN does not fit
# it. 50 is a conservative bound; raise it if the platform accepts more.
ID_MAX_LENGTH="${SECRET_ID_MAX_LENGTH:-50}"
export AWS_REGION

case "$ID_MAX_LENGTH" in
  ''|*[!0-9]*) die "SECRET_ID_MAX_LENGTH '${ID_MAX_LENGTH}' is not a number" ;;
esac
# 20 leaves room for the longest synthetic group id ('rotation-disabled', 17) plus
# a readable prefix on a shortened one.
[ "$ID_MAX_LENGTH" -ge 20 ] || die "SECRET_ID_MAX_LENGTH must be at least 20"

[ -n "$AWS_REGION" ] \
  || die "no region: set the resource's AWS_REGION attribute (arrives as RESOURCE_AWS_REGION), or AWS_REGION when running by hand"

for cmd in aws jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "broker is missing required command: ${cmd}"
done

TMP_DIR="$(mktemp -d)" || die "mktemp -d failed (no writable TMPDIR?)"
chmod 700 "$TMP_DIR"

# ------------------------------------------------------------------------------
# Identity preflight. A credential problem otherwise surfaces as an empty secret
# list, which reads like "this account has no secrets" -- a wrong answer that
# looks like a right one.
# ------------------------------------------------------------------------------
CALLER_JSON="${TMP_DIR}/caller.json"
if ! aws sts get-caller-identity --region "$AWS_REGION" --output json > "$CALLER_JSON" 2>"${TMP_DIR}/caller.err"; then
  die "no usable AWS credentials in ${AWS_REGION}: $(tr '\n' ' ' < "${TMP_DIR}/caller.err" | cut -c1-200)"
fi
AWS_ACCOUNT_ID="$(jq -r '.Account // empty' < "$CALLER_JSON")"
CALLER_ARN="$(jq -r '.Arn // empty' < "$CALLER_JSON")"
[ -n "$AWS_ACCOUNT_ID" ] || die "sts:GetCallerIdentity returned no Account"
info "scanning account ${AWS_ACCOUNT_ID} region ${AWS_REGION} as ${CALLER_ARN}"

# ------------------------------------------------------------------------------
# Enumerate. Filters are ANDed by the API; each is optional.
#   name       matches as a PREFIX, not a substring
#   tag-key    / tag-value are separate filters, so a key+value pair narrows twice
# ------------------------------------------------------------------------------
LIST_ARGS=(secretsmanager list-secrets --region "$AWS_REGION" --output json)
FILTER_DESC="none"
FILTERS=()
[ -n "$SECRET_PREFIX" ]    && FILTERS+=("Key=name,Values=${SECRET_PREFIX}")
[ -n "$SECRET_TAG_KEY" ]   && FILTERS+=("Key=tag-key,Values=${SECRET_TAG_KEY}")
[ -n "$SECRET_TAG_VALUE" ] && FILTERS+=("Key=tag-value,Values=${SECRET_TAG_VALUE}")
if [ "${#FILTERS[@]}" -gt 0 ]; then
  LIST_ARGS+=(--filters "${FILTERS[@]}")
  FILTER_DESC="${FILTERS[*]}"
fi
info "filters: ${FILTER_DESC}"

# --include-planned-deletion surfaces secrets awaiting deletion so they can be
# reported as inactive rather than vanishing silently. It is a newer flag; older
# CLI builds reject it, so fall back rather than fail the whole scan over a
# nice-to-have.
LIST_JSON="${TMP_DIR}/secrets.json"
DELETION_VISIBLE=true
if ! aws "${LIST_ARGS[@]}" --include-planned-deletion > "$LIST_JSON" 2>"${TMP_DIR}/list.err"; then
  DELETION_VISIBLE=false
  info "--include-planned-deletion rejected by this CLI; retrying without it"
  if ! aws "${LIST_ARGS[@]}" > "$LIST_JSON" 2>"${TMP_DIR}/list.err"; then
    die "secretsmanager:ListSecrets failed in ${AWS_REGION}: $(tr '\n' ' ' < "${TMP_DIR}/list.err" | cut -c1-200)"
  fi
fi

# The CLI aggregates pages for --output json, so SecretList holds every page.
SECRET_COUNT="$(jq -r '.SecretList | length' < "$LIST_JSON" 2>/dev/null)" \
  || die "ListSecrets returned output that is not valid JSON"
info "ListSecrets returned ${SECRET_COUNT} secret(s)"

# ------------------------------------------------------------------------------
# Assemble the payload. python stdlib only, no pip dependency on the broker.
# ------------------------------------------------------------------------------
SCAN_JSON="${TMP_DIR}/scan.json"

LIST_JSON="$LIST_JSON" \
OUT_JSON="$SCAN_JSON" \
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
AWS_REGION="$AWS_REGION" \
AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" \
GROUP_TAG_KEY="$GROUP_TAG_KEY" \
FILTER_DESC="$FILTER_DESC" \
DELETION_VISIBLE="$DELETION_VISIBLE" \
ID_MAX_LENGTH="$ID_MAX_LENGTH" \
python3 <<'PYEOF'
import hashlib
import json
import os
import re

with open(os.environ["LIST_JSON"], encoding="utf-8") as handle:
    secrets = json.load(handle).get("SecretList", []) or []

now = os.environ["NOW"]
region = os.environ["AWS_REGION"]
account_id = os.environ["AWS_ACCOUNT_ID"]
group_tag_key = os.environ["GROUP_TAG_KEY"]
id_max = int(os.environ["ID_MAX_LENGTH"])

EMAIL_DOMAIN = f"secretsmanager.{region}.local"
EMAIL_MAX = 64


# ------------------------------------------------------------------------------
# THE IDENTITY ID IS THE SECRET NAME, NOT THE ARN
# ------------------------------------------------------------------------------
# The platform stores it in t_resource_data_account.native_id, which is a short
# column. A full ARN does not fit and the import fails with:
#
#   Data truncation: Data too long for column 'native_id' at row 1
#
# The name is the right key anyway: one resource is one account + region, and a
# secret name is unique within that scope. The full ARN is kept in the
# secret_arn attribute -- attributes go into a JSON column, so length is not a
# problem there, and that is where a rotation reads it from.
#
# A name that is still too long is shortened deterministically rather than
# truncated: plain truncation would collapse 'prod/db/app-primary' and
# 'prod/db/app-replica' onto one id and merge two different secrets.
def shorten(value, limit):
    if len(value) <= limit:
        return value
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]
    if limit <= 9:
        # No room for a readable prefix; the digest alone still disambiguates.
        return digest[:max(limit, 1)]
    return f"{value[:limit - 9]}-{digest}"


# The platform's account table also has NOT NULL email, first_name and last_name
# columns -- an identity without them fails the import with
# "Column 'email' cannot be null" after an otherwise successful scan. A secret has
# no such fields, so a stable synthetic address is derived from its name.
#
# The ARN's trailing 6-character uniquifier is folded in. Sanitising
# 'prod/db/app' gives 'prod-db-app', which a genuinely-named 'prod-db-app' secret
# would collide with; the uniquifier settles it. It also changes when a secret is
# deleted and recreated under the same name, which is correct -- that is a
# different secret.
def synth_email(name, arn):
    local = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.").lower()
    suffix = arn.rsplit("-", 1)[-1] if "-" in arn else ""
    suffix = re.sub(r"[^A-Za-z0-9]+", "", suffix)
    local = f"{local or 'secret'}-{suffix}" if suffix else (local or "secret")
    # The email column is wider than native_id, but not unbounded. Budget the
    # whole address at EMAIL_MAX and shorten the local part, which is the part
    # that varies.
    return f"{shorten(local, EMAIL_MAX - len(EMAIL_DOMAIN) - 1)}@{EMAIL_DOMAIN}"


# Secret names are commonly path-like ('prod/db/app'). Splitting on the last
# slash gives something readable in the two name columns instead of repeating the
# whole path twice.
def split_name(name):
    if "/" in name:
        head, _, tail = name.rpartition("/")
        return head or "NA", tail or "NA"
    return "NA", name or "NA"


def tags_of(secret):
    return {t.get("Key", ""): t.get("Value", "") for t in (secret.get("Tags") or [])}


identities = []
group_members = {}
pending_deletion = 0
service_owned = 0
rotation_on = 0
shortened = 0
seen_ids = {}

for secret in secrets:
    arn = secret.get("ARN") or ""
    name = secret.get("Name") or ""
    if not arn or not name:
        # Nothing can key off this and a rotation could not target it.
        continue

    account_key = shorten(name, id_max)
    if account_key != name:
        shortened += 1
    # Two different secrets must never share an id: the platform would treat the
    # second as an update of the first and one of them would silently vanish.
    if account_key in seen_ids:
        raise SystemExit(
            f"id collision: '{name}' and '{seen_ids[account_key]}' both reduce to "
            f"'{account_key}'. Raise SECRET_ID_MAX_LENGTH or narrow the scan filters."
        )
    seen_ids[account_key] = name

    tags = tags_of(secret)
    deleted = bool(secret.get("DeletedDate"))
    owning_service = secret.get("OwningService") or ""
    rotation_enabled = bool(secret.get("RotationEnabled"))

    if deleted:
        pending_deletion += 1
    if owning_service:
        service_owned += 1
    if rotation_enabled:
        rotation_on += 1

    first_name, last_name = split_name(name)

    identities.append({
        "id": account_key,
        "name": account_key,
        "type": "User",
        "description": (secret.get("Description") or "AWS Secrets Manager secret")[:255],
        "created_on": str(secret.get("CreatedDate") or now),
        "is_active": not deleted,
        "attributes": {
            "email": synth_email(name, arn),
            "first_name": first_name,
            "last_name": last_name,
            # Everything a rotation needs to target this secret without a lookup.
            "secret_arn": arn,
            "secret_name": name,
            "region": region,
            "account_id": account_id,
            "kms_key_id": secret.get("KmsKeyId") or "aws/secretsmanager",
            "rotation_enabled": "true" if rotation_enabled else "false",
            "rotation_lambda_arn": secret.get("RotationLambdaARN") or "",
            "last_rotated_date": str(secret.get("LastRotatedDate") or ""),
            "last_changed_date": str(secret.get("LastChangedDate") or ""),
            "last_accessed_date": str(secret.get("LastAccessedDate") or ""),
            "next_rotation_date": str(secret.get("NextRotationDate") or ""),
            "primary_region": secret.get("PrimaryRegion") or region,
            "owning_service": owning_service,
            "deleted_date": str(secret.get("DeletedDate") or ""),
            "tags": ",".join(f"{k}={v}" for k, v in sorted(tags.items())),
        },
    })

    # Groups: one per distinct value of the chosen tag, plus three synthetic ones
    # that answer the questions actually asked of a secret inventory.
    tag_value = tags.get(group_tag_key)
    if tag_value:
        group_id = shorten(f"{group_tag_key}={tag_value}", id_max)
        group_members.setdefault(group_id, set()).add(account_key)
    group_members.setdefault(
        "rotation-enabled" if rotation_enabled else "rotation-disabled", set()
    ).add(account_key)
    if owning_service:
        group_members.setdefault("service-owned", set()).add(account_key)

SYNTHETIC = {
    "rotation-enabled": "Secrets with AWS-native rotation configured",
    "rotation-disabled": "Secrets with no AWS-native rotation",
    "service-owned": (
        "Secrets created and owned by another AWS service (RDS, Redshift, ...). "
        "These are rotated by that service; rotating them here will desynchronise it"
    ),
}

groups = []
for group_id in sorted(group_members):
    groups.append({
        "id": group_id,
        "name": group_id,
        "type": "User group",
        "description": SYNTHETIC.get(group_id, f"Secrets tagged {group_id}"),
        "created_on": now,
        "is_active": True,
        "members": sorted(group_members[group_id]),
        "attributes": {"group_source": "synthetic" if group_id in SYNTHETIC else "tag"},
    })

details = (
    f"Secrets Manager scan completed for account {account_id} in {region}. "
    f"Secrets: {len(identities)} ({rotation_on} with AWS-native rotation), "
    f"Groups: {len(groups)}. Filters: {os.environ['FILTER_DESC']}"
)
if pending_deletion:
    details += f". Pending deletion, reported inactive: {pending_deletion}"
if os.environ["DELETION_VISIBLE"] != "true":
    details += ". This CLI does not support --include-planned-deletion, so secrets awaiting deletion are not listed"
if service_owned:
    details += (
        f". Service-owned secrets, do NOT rotate through Britive: {service_owned}"
    )
if shortened:
    details += (
        f". Names longer than {id_max} chars, hash-shortened for the native_id "
        f"column: {shortened} (full name and ARN are in the attributes)"
    )

payload = {
    "data": {
        "identities": identities,
        "groups": groups,
        "permissions": [],
        "permission_mapping": [],
    },
    "metadata": {
        "resource_id": f"{account_id}:{region}",
        "resource_type": "AWSSecretsManager",
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

if ! python3 - "$SCAN_JSON" "$ID_MAX_LENGTH" <<'PYEOF' >&2
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
id_max = int(sys.argv[2])

data = payload["data"]
for key in ("identities", "groups", "permissions", "permission_mapping"):
    if not isinstance(data[key], list):
        raise SystemExit(f"data.{key} is not a list")
if not payload["metadata"]["resource_type"]:
    raise SystemExit("metadata.resource_type is empty")

# The NOT NULL columns, checked here rather than discovered at import time.
for identity in data["identities"]:
    for field in ("email", "first_name", "last_name"):
        if not identity["attributes"].get(field):
            raise SystemExit(f"identity {identity['id']} has an empty {field}")

# Column widths, likewise. native_id is short, and overflowing it fails the whole
# import with "Data too long for column 'native_id'" -- which is what putting the
# full ARN here used to do.
for identity in data["identities"]:
    for field in ("id", "name"):
        if len(identity[field]) > id_max:
            raise SystemExit(
                f"identity {field} '{identity[field]}' is {len(identity[field])} chars, over the {id_max} limit"
            )
    if len(identity["attributes"]["email"]) > 64:
        raise SystemExit(f"identity {identity['id']} has an email over 64 chars")
for group in data["groups"]:
    for field in ("id", "name"):
        if len(group[field]) > id_max:
            raise SystemExit(
                f"group {field} '{group[field]}' is {len(group[field])} chars, over the {id_max} limit"
            )

# Every member must resolve to an identity id, or the platform silently drops the
# membership at import.
ids = {identity["id"] for identity in data["identities"]}
if len(ids) != len(data["identities"]):
    raise SystemExit("duplicate identity ids: secret ARNs are not unique in this payload")
dangling = {m for group in data["groups"] for m in group["members"]} - ids
if dangling:
    raise SystemExit(f"{len(dangling)} group member(s) match no identity id, e.g. {sorted(dangling)[:3]}")

# Nothing here should ever look like a secret value.
banned = ("SecretString", "SecretBinary")
blob = json.dumps(payload)
for token in banned:
    if token in blob:
        raise SystemExit(f"payload contains '{token}' -- a secret value must never be scanned")

identity_count = len(data["identities"])
group_count = len(data["groups"])
print(f"validated: {identity_count} secrets, {group_count} groups")
PYEOF
then
  die "assembled scan JSON failed validation"
fi

cat "$SCAN_JSON" > "$OUTPUT_PATH" || die "cannot write scan output to ${OUTPUT_PATH}"
SCAN_COMPLETED=true
info "scan written to ${OUTPUT_PATH} ($(wc -c < "$OUTPUT_PATH" | tr -d ' ') bytes)"
