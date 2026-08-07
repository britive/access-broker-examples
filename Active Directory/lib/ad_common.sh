#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# ad_common.sh — shared Active Directory helpers for Britive broker scripts
# ==============================================================================
# Sourced (never executed) by every script under
# active-directory/permissions/. It replaces the Windows RSAT ActiveDirectory
# PowerShell module used by the original .ps1 examples: this broker is the
# Alpine-based Britive Bridge container, so all AD reads and writes go over
# LDAPS with `ldapsearch` / `ldapmodify` from the `openldap-clients` package.
#
# PowerShell cmdlet -> helper here
# ------------------------------------------------------------------------------
#   Get-ADUser                 ad_get_user / ad_find_user_dn
#   Get-ADGroup                ad_get_group / ad_find_group_dn
#   Get-ADGroupMember -Recursive   ad_is_member_recursive
#   New-ADUser                 ad_create_user
#   Set-ADAccountPassword      ad_set_password
#   Enable-ADAccount           ad_set_account_enabled <dn> <uac> true
#   Disable-ADAccount          ad_set_account_enabled <dn> <uac> false
#   Add-ADGroupMember          ad_group_add_member
#   Remove-ADGroupMember       ad_group_remove_member
#   Sync-ADObject              (no LDAP equivalent — see ad_dc_list / multi-DC
#                              write pattern in group-multi-checkout-force-sync)
#
# LDAPS IS MANDATORY
#   Active Directory refuses `unicodePwd` writes (password set on create and on
#   rotate) over a cleartext connection. ad_init hard-fails on a non-ldaps URI
#   rather than letting the write fail later with an opaque
#   "unwilling to perform" result.
#
# Broker prerequisites (validated at runtime by ad_require_toolkit):
#   ldapsearch, ldapmodify, ldapwhoami   openldap-clients
#   python3                              LDIF base64 + UTF-16LE unicodePwd
#   openssl                              password entropy
#   aws, jq                              only when AD_SECRET is used
#
# Connection env vars (set on the Britive resource / profile, NOT per script):
#   AD_HOST            (required) domain controller FQDN
#   AD_BASE_DN         search base, e.g. DC=contoso,DC=local. Discovered from
#                      RootDSE defaultNamingContext when omitted; set it
#                      explicitly to scope work to a subtree.
#   AD_PORT            LDAPS port (default: 636)
#   AD_SECRET          Secrets Manager id holding {bind_dn|username, password}
#   AD_BIND_DN         bind DN, when AD_SECRET is not used
#   AD_BIND_PASSWORD   bind password, when AD_SECRET is not used
#   AD_USER_OU         OU new accounts land in (default: CN=Users,<AD_BASE_DN>)
#   AD_CA_CERT         CA bundle for LDAPS chain validation
#                      (default: /etc/ssl/certs/ca-certificates.crt)
#   AD_TLS_REQCERT     demand | allow | never (default: demand — never is
#                      test-only and disables server cert validation)
#   AD_TIMEOUT         LDAP network/search timeout, seconds (default: 15)
#   AD_PAGE_SIZE       LDAP paged-results page size, scans only (default: 1000)
#   AWS_REGION         Secrets Manager region (default: us-west-2)
#
# Convention: STDOUT carries ONLY `key: value` lines, which the Britive broker
# parses into response-template variables. Every diagnostic goes to STDERR.
# ==============================================================================

# Guard against double-sourcing: build-standalone.sh inlines this file into a
# script that may also still carry a `. "$AD_COMMON_LIB"` line.
# `return` works when sourced; the `|| exit 0` covers the (unsupported) case of
# executing this file directly.
if [ -n "${AD_COMMON_SH_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only via the sourced-file return path
  return 0 2>/dev/null || exit 0
fi
AD_COMMON_SH_LOADED=1

# ------------------------------------------------------------------------------
# userAccountControl bit flags
# ------------------------------------------------------------------------------
readonly UAC_ACCOUNTDISABLE=2       # 0x0002 account is disabled
readonly UAC_NORMAL_ACCOUNT=512     # 0x0200 ordinary user account, enabled

# ------------------------------------------------------------------------------
# Logging — timestamped, levelled, always STDERR.
# ------------------------------------------------------------------------------
AD_LOG_TAG="${AD_LOG_TAG:-ad}"

_ad_log() {
  printf '%s [%s] %-5s %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$AD_LOG_TAG" "$1" "$2" >&2
}

info()  { _ad_log INFO  "$*"; }
warn()  { _ad_log WARN  "$*"; }
error() { _ad_log ERROR "$*"; }

# Fail fast with a single clear reason on STDERR and a non-zero exit.
die() { error "$*"; exit 1; }

# Emit a response-template variable on STDOUT. The ONLY thing allowed there.
emit() { printf '%s: %s\n' "$1" "$2"; }

# emit_json <key> <value> [<key> <value>...] — the same thing as a single JSON
# object, for permissions whose response template consumes JSON rather than
# "key: value" lines. Must be the ONLY write to STDOUT in such a script:
# a stray line either side makes the whole document unparseable.
#
# Values reach python3 NUL-delimited on STDIN, never in argv or the environment,
# so a generated password is not readable from /proc/<pid>/cmdline or environ by
# anything else in the container. Escaping is json.dumps', so quotes, backslashes
# and the punctuation in a generated passphrase cannot break out of the string.
emit_json() {
  [ $(( $# % 2 )) -eq 0 ] || die "emit_json needs an even number of arguments (got $#)"
  local arg
  for arg in "$@"; do printf '%s\0' "$arg"; done | python3 -c '
import json, sys
parts = sys.stdin.buffer.read().split(b"\0")[:-1]
keys = [p.decode() for p in parts[0::2]]
values = [p.decode() for p in parts[1::2]]
print(json.dumps(dict(zip(keys, values))))
'
}

# ------------------------------------------------------------------------------
# Preflight validation
# ------------------------------------------------------------------------------

# ad_require_cmds <cmd>... — abort listing every missing binary at once, with
# the apk line that installs them, rather than dying one command at a time.
ad_require_cmds() {
  local missing=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "broker is missing required command(s): ${missing[*]}" \
        "-- install on the Bridge image with:" \
        "apk add --no-cache openldap-clients python3 openssl aws-cli jq"
  fi
}

# ad_require_vars <VARNAME>... — abort listing every unset/empty var at once.
ad_require_vars() {
  local missing=() name
  for name in "$@"; do
    [ -n "${!name:-}" ] || missing+=("$name")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing required environment variable(s): ${missing[*]}"
  fi
}

# ad_require_toolkit — the LDAP toolchain every AD script needs. Kept separate
# from ad_require_cmds so scripts can add their own extras.
ad_require_toolkit() {
  ad_require_cmds ldapsearch ldapmodify ldapwhoami python3 openssl base64
  # python3 does the LDIF base64 and UTF-16LE unicodePwd encoding; prove it runs
  # before we build a payload that silently comes out empty.
  python3 -c 'import base64, secrets, sys' \
    || die "python3 present but stdlib (base64/secrets) unusable"
}

# ------------------------------------------------------------------------------
# Scratch state and cleanup
# ------------------------------------------------------------------------------
# The bind password is written to a 0600 file and passed with `ldapsearch -y`.
# `-w <password>` would expose it in /proc/<pid>/cmdline to every process in the
# container for the lifetime of the call.
AD_TMP_DIR=""
AD_PW_FILE=""

ad_cleanup() {
  if [ -n "${AD_TMP_DIR:-}" ] && [ -d "$AD_TMP_DIR" ]; then
    rm -rf "$AD_TMP_DIR"
  fi
}
trap ad_cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Connection setup
# ------------------------------------------------------------------------------

# ad_init — resolve config, stage the bind password, verify the bind works.
# Call once, early, in every script. Anything wrong here is fatal.
ad_init() {
  ad_require_toolkit

  AD_PORT="${AD_PORT:-636}"
  AD_TIMEOUT="${AD_TIMEOUT:-15}"
  AD_PAGE_SIZE="${AD_PAGE_SIZE:-1000}"
  AD_TLS_REQCERT="${AD_TLS_REQCERT:-demand}"
  AD_CA_CERT="${AD_CA_CERT:-/etc/ssl/certs/ca-certificates.crt}"
  AD_SECRET="${AD_SECRET:-}"
  AWS_REGION="${AWS_REGION:-us-west-2}"

  # AD_BASE_DN is NOT required here — it is discovered from RootDSE after the
  # bind when omitted (see below), which needs a working connection first.
  ad_require_vars AD_HOST

  AD_TMP_DIR="$(mktemp -d)" || die "mktemp -d failed (no writable TMPDIR?)"
  chmod 700 "$AD_TMP_DIR"

  # Credentials: Secrets Manager preferred, explicit env vars as the fallback.
  if [ -n "$AD_SECRET" ]; then
    ad_require_cmds aws jq
    info "reading AD bind credentials from Secrets Manager id '$AD_SECRET' ($AWS_REGION)"
    local secret_json
    secret_json="$(aws secretsmanager get-secret-value \
        --secret-id "$AD_SECRET" \
        --region "$AWS_REGION" \
        --query SecretString \
        --output text)" \
      || die "cannot read secret '$AD_SECRET' in $AWS_REGION (check task role permissions)"

    # Accept either {bind_dn,password} or the {username,password} shape used by
    # the other scripts in this repo.
    AD_BIND_DN="$(printf '%s' "$secret_json" | jq -r '.bind_dn // .username // empty')"
    AD_BIND_PASSWORD="$(printf '%s' "$secret_json" | jq -r '.password // empty')"
    unset secret_json

    [ -n "$AD_BIND_DN" ] || die "secret '$AD_SECRET' has no .bind_dn or .username field"
    [ -n "$AD_BIND_PASSWORD" ] || die "secret '$AD_SECRET' has no .password field"
  else
    ad_require_vars AD_BIND_DN AD_BIND_PASSWORD
  fi

  AD_PW_FILE="$AD_TMP_DIR/bindpw"
  ( umask 077; printf '%s' "$AD_BIND_PASSWORD" > "$AD_PW_FILE" ) \
    || die "cannot stage bind password file"
  unset AD_BIND_PASSWORD

  AD_URI="ldaps://${AD_HOST}:${AD_PORT}"

  # AD rejects unicodePwd over cleartext LDAP; refuse up front instead of
  # failing mid-write with "unwilling to perform".
  case "$AD_URI" in
    ldaps://*) : ;;
    *) die "AD account creation and password rotation require LDAPS; refusing $AD_URI" ;;
  esac

  export LDAPTLS_REQCERT="$AD_TLS_REQCERT"
  if [ "$AD_TLS_REQCERT" = "never" ]; then
    warn "AD_TLS_REQCERT=never — the LDAPS server certificate is NOT validated. Test use only."
  elif [ -f "$AD_CA_CERT" ]; then
    export LDAPTLS_CACERT="$AD_CA_CERT"
  else
    warn "AD_CA_CERT '$AD_CA_CERT' not found; relying on the system default trust store"
  fi

  info "AD endpoint $AD_URI | bind '$AD_BIND_DN'"
  ad_verify_bind

  # Discover the domain root from RootDSE when the caller did not name a base DN.
  # Requires an authenticated connection, so it has to follow ad_verify_bind.
  if [ -z "${AD_BASE_DN:-}" ]; then
    AD_BASE_DN="$(ad_rootdse defaultNamingContext)"
    [ -n "$AD_BASE_DN" ] \
      || die "AD_BASE_DN was not set and could not be discovered from RootDSE defaultNamingContext -- set it explicitly"
    info "discovered base DN from RootDSE: '$AD_BASE_DN'"
  else
    info "base DN: '$AD_BASE_DN'"
  fi
}

# ad_verify_bind — prove connectivity, TLS trust and credentials in one call, so
# a later failure is unambiguously about the operation and not the connection.
ad_verify_bind() {
  local whoami_out
  if ! whoami_out="$(ldapwhoami -H "$AD_URI" -x \
        -D "$AD_BIND_DN" -y "$AD_PW_FILE" \
        -o "nettimeout=${AD_TIMEOUT}" 2>&1)"; then
    die "LDAP bind FAILED as '$AD_BIND_DN' against $AD_URI: ${whoami_out//$'\n'/ }"
  fi
  info "LDAP bind OK (${whoami_out//$'\n'/ })"
}

# ------------------------------------------------------------------------------
# LDAP primitives
# ------------------------------------------------------------------------------

# ad_escape_filter <value> — RFC 4515 escaping. `user`, `group`, `prefix` and
# `svcaccount` are platform-supplied strings; without this a value containing
# ()*\ would alter the search filter.
ad_escape_filter() {
  printf '%s' "$1" | sed -e 's/\\/\\5c/g' \
                         -e 's/\*/\\2a/g' \
                         -e 's/(/\\28/g' \
                         -e 's/)/\\29/g'
}

# ad_ldif_b64 <value> — base64 for LDIF `attr::` form, so DNs and names
# containing commas, non-ASCII or leading spaces transport safely.
ad_ldif_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# ad_ldif_value <attr> — read the first value of <attr> from LDIF on STDIN,
# transparently decoding the `attr::` base64 form ldapsearch emits for
# non-ASCII values. Prints nothing when the attribute is absent.
#
# The program is passed with `-c`, NOT as a `python3 - <<'PY'` heredoc like the
# passphrase generators below: `-` makes python read its SCRIPT from stdin, which
# consumes the LDIF this function is supposed to parse and silently yields an
# empty result for every attribute.
ad_ldif_value() {
  python3 -c '
import base64
import sys

attr = sys.argv[1].lower()
for raw in sys.stdin:
    line = raw.rstrip("\r\n")
    lowered = line.lower()
    if lowered.startswith(attr + ":: "):
        sys.stdout.write(base64.b64decode(line[len(attr) + 3:]).decode("utf-8"))
        break
    if lowered.startswith(attr + ": "):
        sys.stdout.write(line[len(attr) + 2:])
        break
' "$1"
}

# ad_search_paged <base> <scope> <filter> [attrs...] — LDIF on STDOUT, using LDAP
# simple paged results.
#
# AD caps a single search response at MaxPageSize (1000 by default) and returns a
# "size limit exceeded" referral rather than the rest, so an unpaged scan of a
# directory with more than 1000 users silently returns only the first page. Only
# the scan scripts need this; the checkout/checkin scripts look up one object at a
# time and use ad_search.
#
# Unlike ad_search this does NOT swallow failure — a partial scan must be an
# error, never a short result that looks complete.
#
# Referral chasing is left at ldapsearch's default, which is OFF (it is opt-in
# via -C). Do NOT add `-o referrals=no`: `-o` accepts only nettimeout and
# ldif-wrap, so anything else makes ldapsearch exit on "Invalid general option
# name" before it ever contacts the DC.
ad_search_paged() {
  local base="$1" scope="$2" filter="$3"
  shift 3
  ldapsearch -LLL -x \
    -o ldif-wrap=no \
    -o "nettimeout=${AD_TIMEOUT}" \
    -E "pr=${AD_PAGE_SIZE:-1000}/noprompt" \
    -H "$AD_URI" \
    -D "$AD_BIND_DN" -y "$AD_PW_FILE" \
    -b "$base" -s "$scope" \
    "$filter" "$@"
}

# ad_rootdse <attr> — read one RootDSE attribute (defaultNamingContext,
# dnsHostName, ...). Works before a base DN is known, so scans can discover it.
ad_rootdse() {
  ad_search "" base "(objectClass=*)" "$1" | ad_ldif_value "$1"
}

# ad_search <base> <scope> <filter> [attrs...] — LDIF on STDOUT.
# `-o ldif-wrap=no` keeps one attribute per line so ad_ldif_value can parse it.
# A "no such object" (32) or empty result is a normal outcome here, so callers
# check for empty output rather than the exit status.
ad_search() {
  local base="$1" scope="$2" filter="$3"
  shift 3
  ldapsearch -LLL -x \
    -o ldif-wrap=no \
    -o "nettimeout=${AD_TIMEOUT}" \
    -H "$AD_URI" \
    -D "$AD_BIND_DN" -y "$AD_PW_FILE" \
    -b "$base" -s "$scope" \
    -l "$AD_TIMEOUT" \
    "$filter" "$@" 2>/dev/null || true
}

# ad_apply <description> — LDIF on STDIN. Logs the AD diagnostic verbatim on
# failure (that text is where AD explains password-policy and ACL rejections)
# and propagates the exit status so callers can fail fast.
ad_apply() {
  local description="$1" output rc=0
  output="$(ldapmodify -x \
      -o "nettimeout=${AD_TIMEOUT}" \
      -H "$AD_URI" \
      -D "$AD_BIND_DN" -y "$AD_PW_FILE" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    error "${description}: FAILED (ldapmodify rc=${rc}) ${output//$'\n'/ | }"
    return "$rc"
  fi
  info "${description}: OK"
}

# ------------------------------------------------------------------------------
# Object lookups
# ------------------------------------------------------------------------------

# ad_get_user <sAMAccountName> — LDIF for the account, empty when absent.
# Equivalent to: Get-ADUser -Filter {SamAccountName -eq $Username}
ad_get_user() {
  local escaped
  escaped="$(ad_escape_filter "$1")"
  ad_search "$AD_BASE_DN" sub \
    "(&(objectCategory=person)(objectClass=user)(sAMAccountName=${escaped}))" \
    dn sAMAccountName userPrincipalName userAccountControl
}

# ad_get_user_by_upn <userPrincipalName> — LDIF for the account, empty when
# absent. Equivalent to: Get-ADUser -Filter "UserPrincipalName -eq '$user'"
ad_get_user_by_upn() {
  local escaped
  escaped="$(ad_escape_filter "$1")"
  ad_search "$AD_BASE_DN" sub \
    "(&(objectCategory=person)(objectClass=user)(userPrincipalName=${escaped}))" \
    dn sAMAccountName userPrincipalName userAccountControl
}

# ad_find_user_dn <sAMAccountName> — the DN alone, empty when absent.
ad_find_user_dn() { ad_get_user "$1" | ad_ldif_value dn; }

# ad_count_entries — number of entries in LDIF on STDIN, by counting dn lines.
ad_count_entries() { grep -c '^dn:' || true; }

# ad_resolve_identity <email> — find the AD account belonging to a Britive
# identity, printing its LDIF (empty when nothing matches).
#
# WHY THIS EXISTS
#   A Britive identity is an email in the company's public domain
#   (jdoe@contoso.com) while the AD account's userPrincipalName usually carries
#   the internal AD suffix (jdoe@contoso.local). Matching on userPrincipalName
#   alone — as the PowerShell originals did — therefore finds nothing in most
#   real directories, and the permission fails with "user does not exist" even
#   though the account is right there.
#
# PRECEDENCE. The first strategy that matches wins:
#   1. sAMAccountName == <local part>        jdoe@contoso.com -> jdoe
#   2. userPrincipalName == <email>          when the suffixes do align
#   3. mail == <email>                       the directory's own email attribute
#
# The local part goes FIRST deliberately. It is the same derivation every other
# permission here already uses (ad_sam_from_email, which only adds the -a / sa-
# affix on top), so every flow now locates, creates and updates accounts off one
# rule. Matching on the UPN first meant add-user-to-group could resolve a
# different account than the affix flows would for the same requester.
#
# A strategy matching MORE THAN ONE account is fatal rather than first-wins:
# picking arbitrarily between two humans would grant access to the wrong person.
# (sAMAccountName is unique per domain, so strategy 1 cannot return more than one.)
#
# Set AD_STRICT_UPN=true to use userPrincipalName only, reproducing the
# PowerShell originals' behaviour.
ad_resolve_identity() {
  local email="$1" ldif count escaped

  if [ "${AD_STRICT_UPN:-false}" = "true" ]; then
    ldif="$(ad_get_user_by_upn "$email")"
    count="$(printf '%s\n' "$ldif" | ad_count_entries)"
    if [ "$count" -gt 1 ]; then
      die "email '${email}' matches ${count} accounts by userPrincipalName; refusing to guess which one to use"
    fi
    if [ "$count" -eq 1 ]; then
      info "resolved '${email}' by userPrincipalName (AD_STRICT_UPN=true)"
      printf '%s' "$ldif"
    else
      info "no userPrincipalName match for '${email}' and AD_STRICT_UPN=true, so not trying sAMAccountName or mail"
    fi
    return 0
  fi

  # ---- 1. sAMAccountName from the local part ----
  local local_part="${email%%@*}"
  local sanitized="${local_part//[^a-zA-Z0-9._-]/}"
  if [ "$sanitized" != "$local_part" ]; then
    warn "email local part '${local_part}' contains characters invalid in a sAMAccountName; searching for '${sanitized}' -- verify this is not another user's account"
  fi
  local_part="$sanitized"

  if [ -n "$local_part" ]; then
    ldif="$(ad_get_user "$local_part")"
    if [ "$(printf '%s\n' "$ldif" | ad_count_entries)" -eq 1 ]; then
      info "resolved '${email}' by sAMAccountName '${local_part}'"
      printf '%s' "$ldif"
      return 0
    fi
    info "no account with sAMAccountName '${local_part}' — falling back to userPrincipalName, then mail"
  fi

  # ---- 2. userPrincipalName ----
  ldif="$(ad_get_user_by_upn "$email")"
  count="$(printf '%s\n' "$ldif" | ad_count_entries)"
  if [ "$count" -gt 1 ]; then
    die "email '${email}' matches ${count} accounts by userPrincipalName; refusing to guess which one to use"
  fi
  if [ "$count" -eq 1 ]; then
    info "resolved '${email}' by userPrincipalName"
    printf '%s' "$ldif"
    return 0
  fi

  # ---- 3. mail ----
  escaped="$(ad_escape_filter "$email")"
  ldif="$(ad_search "$AD_BASE_DN" sub \
    "(&(objectCategory=person)(objectClass=user)(mail=${escaped}))" \
    dn sAMAccountName userPrincipalName userAccountControl)"
  count="$(printf '%s\n' "$ldif" | ad_count_entries)"
  if [ "$count" -gt 1 ]; then
    die "email '${email}' matches ${count} accounts by mail; refusing to guess which one to use"
  fi
  if [ "$count" -eq 1 ]; then
    info "resolved '${email}' by the mail attribute"
    printf '%s' "$ldif"
    return 0
  fi

  return 0
}

# ad_find_group_dn <name> — DN of a group matched on sAMAccountName OR cn.
# The PowerShell originals matched on Name (= cn) in some scripts and passed the
# value to -Identity (= sAMAccountName) in others; accepting both keeps existing
# Britive profiles working unchanged.
ad_find_group_dn() {
  local escaped
  escaped="$(ad_escape_filter "$1")"
  ad_search "$AD_BASE_DN" sub \
    "(&(objectClass=group)(|(sAMAccountName=${escaped})(cn=${escaped})))" dn \
    | ad_ldif_value dn
}

# ad_is_member_recursive <groupDN> <userDN> — true when the user is a direct or
# nested member. Uses AD's LDAP_MATCHING_RULE_IN_CHAIN (1.2.840.113556.1.4.1941),
# the server-side equivalent of Get-ADGroupMember -Recursive.
#
# CAVEAT: an account's PRIMARY group (normally "Domain Users") is recorded in the
# user's primaryGroupID attribute, not in the group's `member` attribute, so this
# returns false for it. That is the right answer for these scripts — a primary
# group is not something a checkout grants or a checkin can revoke — but do not
# point a Britive profile at Domain Users and expect the membership check to see
# pre-existing members.
ad_is_member_recursive() {
  local group_dn="$1" escaped_user_dn
  escaped_user_dn="$(ad_escape_filter "$2")"
  local found
  found="$(ad_search "$group_dn" base \
    "(member:1.2.840.113556.1.4.1941:=${escaped_user_dn})" dn | ad_ldif_value dn)"
  [ -n "$found" ]
}

# ------------------------------------------------------------------------------
# Identity naming
# ------------------------------------------------------------------------------

# ad_sam_from_email <email> [prefix] [suffix] — build and validate a
# sAMAccountName from the local part of an email, e.g. jdoe@x.com + "-a"
# suffix -> "jdoe-a", or "sa-" prefix -> "sa-jdoe".
# Drops characters AD disallows and enforces the 20-character ceiling, which the
# PowerShell originals silently violated for long usernames.
ad_sam_from_email() {
  local email="$1" prefix="${2:-}" suffix="${3:-}" local_part sam

  case "$email" in
    *@*) local_part="${email%%@*}" ;;
    *)   die "invalid email format: '$email' (expected user@domain)" ;;
  esac

  # Keep only characters valid and unambiguous in a sAMAccountName. Warn when
  # anything was dropped: "jdoe+ops@x" and "jdoeops@x" both collapse to "jdoeops",
  # so silent stripping could map two different requesters onto one account.
  local sanitized="${local_part//[^a-zA-Z0-9._-]/}"
  if [ "$sanitized" != "$local_part" ]; then
    warn "email local part '${local_part}' contains characters invalid in a sAMAccountName; using '${sanitized}' -- verify this does not collide with another user's account"
  fi
  local_part="$sanitized"
  [ -n "$local_part" ] || die "cannot derive an account name from email '$email'"

  sam="${prefix}${local_part}${suffix}"
  if [ "${#sam}" -gt 20 ]; then
    die "derived sAMAccountName '$sam' is ${#sam} chars; AD allows at most 20"
  fi
  printf '%s' "$sam"
}

# ------------------------------------------------------------------------------
# Password generation
# ------------------------------------------------------------------------------

# ad_gen_password [length] — random password meeting AD's default complexity
# rule (3 of 4 character classes).
#
# openssl is the entropy source rather than `tr -dc ... < /dev/urandom`: tr
# aborts with "Illegal byte sequence" on raw binary in any non-C locale and
# silently yields a 1-2 character password. The length assertion turns any
# future generator regression into a hard error instead of a weak credential.
ad_gen_password() {
  local length="${1:-16}" body body_len
  [ "$length" -ge 12 ] || die "refusing to generate a password shorter than 12 chars"
  body_len=$(( length - 4 ))

  body="$(openssl rand -base64 128 | tr -dc 'A-Za-z0-9' | head -c "$body_len")"
  if [ "${#body}" -ne "$body_len" ]; then
    die "password generation failed (got ${#body} chars, expected ${body_len})"
  fi
  # Fixed 4-char tail guarantees upper + lower + digit + symbol regardless of
  # what the RNG produced.
  printf '%sAa9!' "$body"
}

# ad_gen_passphrase_pronounceable [min-length] — consonant/vowel pseudo-words,
# port of New-PronounceableWord from rotate-a-account-checkout-passphrase.ps1.
# Output looks like "Vamob Ketised Nuk47".
ad_gen_passphrase_pronounceable() {
  python3 - "${1:-18}" <<'PY'
import secrets
import sys

CONSONANTS = "bdfghjklmnprstvwz"
VOWELS = "aeiou"


def word(syllables: int) -> str:
    out = []
    for _ in range(syllables):
        out.append(secrets.choice(CONSONANTS))
        out.append(secrets.choice(VOWELS))
    # Trailing consonant gives the pseudo-word a more word-like shape.
    out.append(secrets.choice(CONSONANTS))
    return "".join(out)


min_length = int(sys.argv[1])
words = []
while len("".join(words)) < min_length:
    words.append(word(secrets.choice((2, 3))).capitalize())

# Two trailing digits satisfy AD complexity without hurting memorability.
sys.stdout.write("".join(words) + str(secrets.randbelow(90) + 10))
PY
}

# ad_gen_passphrase_english [min-length] — English onset + rime pseudo-words
# joined with dashes, port of New-EnglishWord from
# rotate-sa-account-passphrase.ps1. Output looks like "Blaze-Creed-Stork-Vine42".
ad_gen_passphrase_english() {
  python3 - "${1:-14}" <<'PY'
import secrets
import sys

ONSETS = (
    "b", "bl", "br", "c", "ch", "cl", "cr", "d", "dr", "f", "fl", "fr",
    "g", "gl", "gr", "h", "j", "k", "l", "m", "n", "p", "pl", "pr",
    "r", "s", "sc", "sh", "sk", "sl", "sm", "sn", "sp", "st", "str",
    "sw", "t", "th", "tr", "tw", "v", "w", "wh", "z",
)

RIMES = (
    "ace", "ade", "aft", "age", "ail", "ain", "ake", "ale", "all", "ame",
    "amp", "ane", "ank", "ark", "arm", "art", "ash", "ast", "ate", "awn",
    "aze", "ead", "eal", "eam", "ear", "eat", "eck", "eed", "eel", "een",
    "eep", "ell", "end", "ent", "ess", "est", "ew", "ice", "ick", "ide",
    "ife", "ift", "ight", "ill", "ine", "ing", "ink", "ire", "isk", "ist",
    "ite", "ive", "oad", "oam", "oar", "oat", "ock", "ode", "oil", "oke",
    "old", "oll", "ome", "one", "ong", "ood", "ook", "ool", "oom", "oon",
    "oop", "ore", "ork", "orn", "ort", "ose", "ost", "ound", "out", "ove",
    "ow", "own", "ub", "uck", "uff", "uge", "ull", "ump", "ung", "unk",
    "urn", "ush", "ust", "ute",
)

min_length = int(sys.argv[1])
words = []
while len("-".join(words)) < min_length:
    words.append((secrets.choice(ONSETS) + secrets.choice(RIMES)).capitalize())

sys.stdout.write("-".join(words) + str(secrets.randbelow(90) + 10))
PY
}

# ------------------------------------------------------------------------------
# Write operations
# ------------------------------------------------------------------------------

# ad_encode_unicode_pwd <plaintext> — AD stores passwords in `unicodePwd` as the
# plaintext wrapped in literal double quotes, encoded UTF-16LE, then base64 for
# LDIF transport. Any deviation yields "unwilling to perform" with no detail.
ad_encode_unicode_pwd() {
  printf '%s' "$1" | python3 -c '
import base64
import sys

plaintext = sys.stdin.read()
quoted = f"\"{plaintext}\"".encode("utf-16-le")
sys.stdout.write(base64.b64encode(quoted).decode("ascii"))
'
}

# ad_set_password <userDN> <plaintext> — Set-ADAccountPassword -Reset.
# `replace` (not `add`/`delete`) is the administrative reset form and does not
# require the previous password.
ad_set_password() {
  local user_dn="$1" plaintext="$2"
  ad_apply "reset password on ${user_dn}" <<EOF
dn:: $(ad_ldif_b64 "$user_dn")
changetype: modify
replace: unicodePwd
unicodePwd:: $(ad_encode_unicode_pwd "$plaintext")
EOF
}

# ad_uac_is_disabled <userAccountControl> — true when the ACCOUNTDISABLE bit set.
ad_uac_is_disabled() {
  local uac="${1:-0}"
  [ $(( uac & UAC_ACCOUNTDISABLE )) -ne 0 ]
}

# ad_set_account_enabled <userDN> <currentUAC> <true|false>
# Enable-ADAccount / Disable-ADAccount. Flips only the ACCOUNTDISABLE bit so
# other flags (DONT_EXPIRE_PASSWORD, SMARTCARD_REQUIRED, ...) survive, which a
# blind `replace userAccountControl: 512` would destroy. No-ops when already in
# the requested state.
ad_set_account_enabled() {
  local user_dn="$1" current_uac="${2:-$UAC_NORMAL_ACCOUNT}" want_enabled="$3" new_uac

  if [ "$want_enabled" = "true" ]; then
    new_uac=$(( current_uac & ~UAC_ACCOUNTDISABLE ))
  else
    new_uac=$(( current_uac | UAC_ACCOUNTDISABLE ))
  fi

  if [ "$new_uac" -eq "$current_uac" ]; then
    info "userAccountControl already ${current_uac} (enabled=${want_enabled}) — no change needed"
    return 0
  fi

  ad_apply "set userAccountControl ${current_uac} -> ${new_uac} on ${user_dn}" <<EOF
dn:: $(ad_ldif_b64 "$user_dn")
changetype: modify
replace: userAccountControl
userAccountControl: ${new_uac}
EOF
}

# ad_create_user <sam> <upn> <displayName> <plaintext> [extra LDIF lines...]
# New-ADUser. Prints the created DN on STDOUT.
#
# unicodePwd and userAccountControl are set in the SAME add operation: adding
# the object first and setting the password afterwards leaves a window in which
# a password-less enabled account exists in the directory.
ad_create_user() {
  local sam="$1" upn="$2" display_name="$3" plaintext="$4"
  shift 4

  local target_ou="${AD_USER_OU:-CN=Users,${AD_BASE_DN}}"
  local user_dn="CN=${sam},${target_ou}"
  local ldif extra

  ldif="$(cat <<EOF
dn:: $(ad_ldif_b64 "$user_dn")
changetype: add
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: user
cn:: $(ad_ldif_b64 "$sam")
sAMAccountName:: $(ad_ldif_b64 "$sam")
userPrincipalName:: $(ad_ldif_b64 "$upn")
displayName:: $(ad_ldif_b64 "$display_name")
unicodePwd:: $(ad_encode_unicode_pwd "$plaintext")
userAccountControl: ${UAC_NORMAL_ACCOUNT}
EOF
)"

  # Optional caller-supplied attributes (description, givenName, company, ...).
  for extra in "$@"; do
    [ -n "$extra" ] && ldif="${ldif}"$'\n'"${extra}"
  done

  printf '%s\n' "$ldif" | ad_apply "create user ${user_dn}" \
    || die "could not create '${sam}' in '${target_ou}' (does the OU exist and does the bind account have Create Child rights?)"

  printf '%s' "$user_dn"
}

# ad_unlock_account <userDN> — Unlock-ADAccount.
#
# Clears the lockout by writing lockoutTime=0. AD treats 0 as "not locked out";
# there is no separate unlock operation over LDAP. Safe to call on an account that
# was never locked.
ad_unlock_account() {
  ad_apply "unlock account ${1}" <<EOF
dn:: $(ad_ldif_b64 "$1")
changetype: modify
replace: lockoutTime
lockoutTime: 0
EOF
}

# ad_clear_must_change_password <userDN> — Set-ADUser -ChangePasswordAtLogon $false.
#
# pwdLastSet is a magic attribute accepting only two values: 0 forces a change at
# next logon, -1 stamps it with the current time and clears that requirement.
# Needed after an administrative reset, which otherwise leaves the account
# flagged must-change — fatal for a service account that can never answer the
# interactive prompt.
ad_clear_must_change_password() {
  ad_apply "clear must-change-password on ${1}" <<EOF
dn:: $(ad_ldif_b64 "$1")
changetype: modify
replace: pwdLastSet
pwdLastSet: -1
EOF
}

# ad_group_add_member <groupDN> <userDN> — Add-ADGroupMember.
ad_group_add_member() {
  ad_apply "add ${2} to group ${1}" <<EOF
dn:: $(ad_ldif_b64 "$1")
changetype: modify
add: member
member:: $(ad_ldif_b64 "$2")
EOF
}

# ad_group_remove_member <groupDN> <userDN> — Remove-ADGroupMember -Confirm:$false.
ad_group_remove_member() {
  ad_apply "remove ${2} from group ${1}" <<EOF
dn:: $(ad_ldif_b64 "$1")
changetype: modify
delete: member
member:: $(ad_ldif_b64 "$2")
EOF
}

# ad_attr_line <attr> <value> — build one optional LDIF attribute line for
# ad_create_user, or nothing when the value is empty.
ad_attr_line() {
  [ -n "${2:-}" ] || return 0
  printf '%s:: %s' "$1" "$(ad_ldif_b64 "$2")"
}
