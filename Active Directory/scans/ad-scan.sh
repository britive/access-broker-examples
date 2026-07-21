#!/bin/sh
set -eu

# ============================================================
# Active Directory IAM-Style Broker Scan (runs on the Linux broker)
# ============================================================
# Shell version of the ad-scan PowerShell scripts. Instead of the
# RSAT ActiveDirectory module on a Windows broker, this runs on a
# Linux broker and queries a Domain Controller over LDAP with
# `ldapsearch`. An embedded python3 (stdlib only) parses the LDIF
# and emits the Britive Resource Manager JSON; the broker captures,
# validates, and writes it.
#
# Best of both PowerShell variants:
#   - Group membership is inverted from each user's memberOf, so it
#     is NOT subject to the group-side ~5000 range truncation that
#     bulk Member retrieval hits (the ad-scan_2.ps1 weakness), while
#     still resolving user members only (both variants' behavior).
#   - CNF (replication-conflict) groups are skipped and group names
#     are sanitized/truncated (the ad-scan_2.ps1 strengths).
#   - Paged results (default 1000/page) so directories with >1000
#     users or groups are fully enumerated.
#
# Broker-injected resource params (plaintext env vars):
#   RESOURCE_HOST      – Domain Controller hostname/IP            (required)
#   RESOURCE_USER      – bind user (UPN user@domain or DOMAIN\\user) (required)
#   RESOURCE_PASSWORD  – bind password                            (required)
#
# Broker-supplied:
#   BROKER_INJECTED_SCAN_OUTPUT_PATH – full path for JSON output  (required)
#
# Optional:
#   RESOURCE_BASE_DN   – search base (default: RootDSE defaultNamingContext)
#   LDAP_PROTOCOL      – ldap (default) or ldaps
#   LDAP_PORT          – default 389 (ldap) / 636 (ldaps)
#   LDAP_START_TLS     – 1 to issue StartTLS on a plain ldap connection (default 0)
#   PAGE_SIZE          – LDAP paged-results page size (default 1000)
#
# NOTE: plain ldap sends the bind password in cleartext — prefer
# ldaps or LDAP_START_TLS=1 in production. The password is passed to
# ldapsearch via a 0600 file (never on the command line).
# ============================================================

# ---- broker-side validation -------------------------------
if [ -z "${BROKER_INJECTED_SCAN_OUTPUT_PATH:-}" ]; then
    echo "ERROR: BROKER_INJECTED_SCAN_OUTPUT_PATH not set. Cannot write scan output." >&2
    exit 1
fi
OUTPUT_PATH="$BROKER_INJECTED_SCAN_OUTPUT_PATH"

DC_HOST="${RESOURCE_HOST:-}"
BIND_USER="${RESOURCE_USER:-}"
BIND_PASS="${RESOURCE_PASSWORD:-}"
BASE_DN="${RESOURCE_BASE_DN:-}"
LDAP_PROTOCOL="${LDAP_PROTOCOL:-ldap}"
LDAP_START_TLS="${LDAP_START_TLS:-0}"
PAGE_SIZE="${PAGE_SIZE:-1000}"

if [ "$LDAP_PROTOCOL" = "ldaps" ]; then
    LDAP_PORT="${LDAP_PORT:-636}"
else
    LDAP_PORT="${LDAP_PORT:-389}"
fi
LDAP_URI="${LDAP_PROTOCOL}://${DC_HOST}:${LDAP_PORT}"

OUT_DIR="$(dirname "$OUTPUT_PATH")"
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR"

# ---- error JSON helper ------------------------------------
# write_error <message>
write_error() {
    _msg="$1"
    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _msg_esc="$(printf '%s' "$_msg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    cat > "$OUTPUT_PATH" <<EOF
{
  "data": { "identities": [], "groups": [], "permissions": [], "permission_mapping": [] },
  "metadata": { "scan_errors": "$_msg_esc", "scan_time": "$_now" }
}
EOF
}

# ---- fail-fast checks -------------------------------------
command -v ldapsearch >/dev/null 2>&1 || { write_error "ldapsearch not found on broker (install openldap-clients)"; echo "ERROR: ldapsearch not found" >&2; exit 1; }
command -v python3   >/dev/null 2>&1 || { write_error "python3 not found on broker"; echo "ERROR: python3 not found" >&2; exit 1; }
[ -n "$DC_HOST" ]   || { write_error "RESOURCE_HOST empty"; echo "ERROR: RESOURCE_HOST empty" >&2; exit 1; }
[ -n "$BIND_USER" ] || { write_error "RESOURCE_USER empty"; echo "ERROR: RESOURCE_USER empty" >&2; exit 1; }
[ -n "$BIND_PASS" ] || { write_error "RESOURCE_PASSWORD empty"; echo "ERROR: RESOURCE_PASSWORD empty" >&2; exit 1; }

echo "Running AD IAM-style broker scan against $LDAP_URI ..." >&2
echo "Output path: $OUTPUT_PATH" >&2

# ---- temp files & cleanup ---------------------------------
PW_FILE="$(mktemp)"
USERS_LDIF="$(mktemp)"
GROUPS_LDIF="$(mktemp)"
TMP_ERR="$(mktemp)"
TMP_OUT="$(mktemp)"
chmod 600 "$PW_FILE" "$USERS_LDIF" "$GROUPS_LDIF"
trap 'rm -f "$PW_FILE" "$USERS_LDIF" "$GROUPS_LDIF" "$TMP_ERR" "$TMP_OUT"' EXIT INT TERM
umask 077

printf '%s' "$BIND_PASS" > "$PW_FILE"

# StartTLS flag for plain ldap connections
TLS_FLAG=""
[ "$LDAP_PROTOCOL" = "ldap" ] && [ "$LDAP_START_TLS" = "1" ] && TLS_FLAG="-ZZ"

# common ldapsearch args: simple bind, password from file, no line wrap,
# attrs-and-values only, paged results, referrals off (AD chases them badly)
# shellcheck disable=SC2086
ldap_query() {
    _base="$1"; _scope="$2"; _filter="$3"; shift 3
    ldapsearch -x -o ldif-wrap=no -LLL $TLS_FLAG \
        -H "$LDAP_URI" \
        -D "$BIND_USER" -y "$PW_FILE" \
        -E "pr=${PAGE_SIZE}/noprompt" \
        -o referrals=no \
        -s "$_scope" -b "$_base" \
        "$_filter" "$@"
}

# ---- resolve base DN via RootDSE if not provided ----------
if [ -z "$BASE_DN" ]; then
    if ! ldap_query "" base "(objectClass=*)" defaultNamingContext > "$TMP_OUT" 2>"$TMP_ERR"; then
        write_error "LDAP bind/connect failed: $(cat "$TMP_ERR")"
        echo "ERROR: LDAP bind failed" >&2
        exit 1
    fi
    BASE_DN="$(sed -n 's/^defaultNamingContext: //p' "$TMP_OUT" | head -n 1)"
    [ -n "$BASE_DN" ] || { write_error "could not determine base DN from RootDSE (set RESOURCE_BASE_DN)"; echo "ERROR: no base DN" >&2; exit 1; }
    echo "Discovered base DN: $BASE_DN" >&2
fi

# ---- query users and groups -------------------------------
# Users: memberOf is used to invert group membership (avoids group-side range).
if ! ldap_query "$BASE_DN" sub "(&(objectCategory=person)(objectClass=user))" \
        sAMAccountName mail givenName sn userPrincipalName userAccountControl memberOf \
        > "$USERS_LDIF" 2>"$TMP_ERR"; then
    write_error "user query failed: $(cat "$TMP_ERR")"
    echo "ERROR: user query failed" >&2
    exit 1
fi

if ! ldap_query "$BASE_DN" sub "(objectClass=group)" \
        sAMAccountName cn name \
        > "$GROUPS_LDIF" 2>"$TMP_ERR"; then
    write_error "group query failed: $(cat "$TMP_ERR")"
    echo "ERROR: group query failed" >&2
    exit 1
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- parse LDIF and assemble Britive JSON (python3 stdlib) ----
if ! BASE_DN="$BASE_DN" NOW="$NOW" USERS_LDIF="$USERS_LDIF" GROUPS_LDIF="$GROUPS_LDIF" \
    python3 - > "$TMP_OUT" 2>"$TMP_ERR" <<'PYEOF'
import os, re, sys, json, base64

def parse_ldif(path):
    entries, cur = [], None
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n').rstrip('\r')
            if line == '':
                if cur is not None:
                    entries.append(cur); cur = None
                continue
            if line.startswith('#'):
                continue
            m = re.match(r'^([^:]+)(::?)[ ]?(.*)$', line)
            if not m:
                continue
            attr, sep, val = m.group(1), m.group(2), m.group(3)
            if sep == '::':
                try:
                    val = base64.b64decode(val).decode('utf-8', 'replace')
                except Exception:
                    pass
            if cur is None:
                cur = {}
            cur.setdefault(attr, []).append(val)
    if cur is not None:
        entries.append(cur)
    return entries

def first(e, k, default=''):
    v = e.get(k)
    return v[0] if v else default

base_dn = os.environ['BASE_DN']
now     = os.environ['NOW']
domain  = '.'.join(re.findall(r'DC=([^,]+)', base_dn, re.I)) or 'ad.local'

users  = parse_ldif(os.environ['USERS_LDIF'])
groups = parse_ldif(os.environ['GROUPS_LDIF'])

# invert membership from each user's memberOf: group DN (lowercased) -> {sam}
membership = {}
identities = []
for u in users:
    sam = first(u, 'sAMAccountName')
    if not sam:
        continue
    uac = first(u, 'userAccountControl', '0')
    try:
        disabled = bool(int(uac) & 0x2)   # ACCOUNTDISABLE
    except ValueError:
        disabled = False
    mail = first(u, 'mail') or (sam + '@' + domain)   # email must be non-null
    identities.append({
        'id': sam, 'name': sam, 'type': 'User',
        'description': 'Active Directory user', 'created_on': now,
        'is_active': (not disabled),
        'attributes': {
            'email': mail,
            'first_name': first(u, 'givenName') or 'NA',
            'last_name': first(u, 'sn') or 'NA',
            'samaccountname': sam,
            'user_principal_name': first(u, 'userPrincipalName'),
            'distinguished_name': first(u, 'dn'),
        },
    })
    for gdn in u.get('memberOf', []):
        membership.setdefault(gdn.lower(), set()).add(sam)

groups_out = []
cnf_skipped = 0
for g in groups:
    dn = first(g, 'dn')
    name = first(g, 'cn') or first(g, 'name') or first(g, 'sAMAccountName')
    # skip replication-conflict (CNF) objects
    if 'CNF:' in dn or 'CNF:' in name:
        cnf_skipped += 1
        continue
    name = re.sub(r'[\r\n\t]', ' ', name).strip()[:255]
    gsam = first(g, 'sAMAccountName') or name
    members = sorted(membership.get(dn.lower(), set()))
    groups_out.append({
        'id': gsam, 'name': name, 'type': 'User group',
        'description': 'Active Directory group', 'created_on': now,
        'is_active': True, 'members': members,
        'attributes': {'samaccountname': gsam, 'distinguished_name': dn},
    })

out = {
    'data': {
        'identities': identities,
        'groups': groups_out,
        'permissions': [],
        'permission_mapping': [],
    },
    'metadata': {
        'resource_id': base_dn,
        'resource_type': 'ActiveDirectory',
        'scan_time': now,
        'scan_details': 'AD scan completed. Users: %d, Groups: %d, CNF skipped: %d'
                        % (len(identities), len(groups_out), cnf_skipped),
        'scan_errors': '',
        'attribute_resolution': {'group_membership': 'id', 'permission_mapping': 'id'},
    },
}
json.dump(out, sys.stdout)
PYEOF
then
    write_error "failed to assemble scan JSON: $(cat "$TMP_ERR")"
    echo "ERROR: JSON assembly failed: $(cat "$TMP_ERR")" >&2
    exit 1
fi

# ---- validate and write -----------------------------------
if [ ! -s "$TMP_OUT" ]; then
    write_error "scan produced no output"
    echo "ERROR: empty scan output" >&2
    exit 1
fi
case "$(head -c 1 "$TMP_OUT")" in
    '{') : ;;
    *) write_error "scan produced non-JSON output"; echo "ERROR: non-JSON output" >&2; exit 1 ;;
esac

if ! cat "$TMP_OUT" > "$OUTPUT_PATH"; then
    echo "ERROR: failed to write scan output to $OUTPUT_PATH" >&2
    exit 1
fi

echo "AD broker scan completed successfully." >&2
exit 0
