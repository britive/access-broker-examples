#!/bin/bash
# ==============================================================================
# DIAGNOSTIC: dump the environment the broker actually provides
# ==============================================================================
# Not a real rotation. Answers one question: which variables does the broker put
# in scope for THIS action, and what are their values?
#
# Wire it up as the rotation script on a resource type (it also works unchanged as
# a checkout, checkin or scan script), run it, and read the output in the broker
# log. It changes nothing — no LDAP connection, no AWS call, no writes.
#
# ------------------------------------------------------------------------------
# WHY THE NAMES COME FIRST
# ------------------------------------------------------------------------------
# Britive truncates the captured output at roughly 250 characters, and CloudWatch
# holds nothing more. A dump that starts with values gets cut off before it
# reaches the interesting part, so this prints:
#
#   1. env_names          -- every variable name, one line, comma separated
#   2. env_count / groups -- how many, and how many per prefix
#   3. the values         -- grouped, most relevant prefix first
#
# Even a hard truncation therefore still tells you whether RESOURCE_HOST and
# friends exist, which is the actual question.
#
# ------------------------------------------------------------------------------
# WHERE TO READ THE OUTPUT
# ------------------------------------------------------------------------------
# STDOUT goes to the broker's captured action output (response.errorDetail on a
# failure, the response payload on success). STDERR is written too, because which
# of the two a given action surfaces is not consistent.
#
# If the successful-run output is not visible anywhere, set ENV_DUMP_FAIL=true:
# the script then exits 1 after printing, which forces the text into
# response.errorDetail, where it is definitely logged (still truncated, hence the
# ordering above).
#
# Optional env vars:
#   ENV_DUMP_FORMAT  json (default) | keyvalue    output shape on STDOUT
#   ENV_DUMP_FAIL    true to exit 1 after printing (see above); default false
#   ENV_DUMP_REVEAL  true to print credential values in full. Default false, and
#                    leaving it false is strongly preferred — see below.
#
# ------------------------------------------------------------------------------
# WHAT IS MASKED, AND WHAT IS NOT
# ------------------------------------------------------------------------------
# Anything whose NAME looks credential-bearing (PASSWORD, TOKEN, PRIVATE_KEY,
# CREDENTIAL, AUTH, PWD, PASSPHRASE) is replaced with its length and a short
# SHA-256 prefix. That is enough to confirm a value arrived, and to tell two
# values apart, without putting the plaintext into a log that gets shipped
# somewhere else.
#
# Names containing SECRET are shown IN FULL and deliberately so: in this repo a
# *_SECRET variable holds a Secrets Manager identifier (demo/ad-bind), not a
# password, and hiding it would defeat the point of running this. If your tenant
# puts an actual password in such a variable, run with the value masked by adding
# it to MASK_EXTRA below before you run this in an environment whose logs leave
# your account.
# ==============================================================================

set -uo pipefail

FORMAT="${ENV_DUMP_FORMAT:-json}"
FAIL_AFTER="${ENV_DUMP_FAIL:-false}"
REVEAL="${ENV_DUMP_REVEAL:-false}"

# Extra names to mask, space separated, if your tenant carries a password in a
# variable this script would otherwise print.
MASK_EXTRA=""

TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ------------------------------------------------------------------------------
# The dump itself is python: it reads os.environ directly, so a value containing
# newlines, quotes or shell metacharacters cannot corrupt the output or be
# re-interpreted by the shell.
# ------------------------------------------------------------------------------
ENV_DUMP_FORMAT="$FORMAT" \
ENV_DUMP_REVEAL="$REVEAL" \
ENV_DUMP_MASK_EXTRA="$MASK_EXTRA" \
ENV_DUMP_TS="$TS" \
python3 <<'PYEOF'
import hashlib
import json
import os
import sys

fmt = os.environ.get("ENV_DUMP_FORMAT", "json")
reveal = os.environ.get("ENV_DUMP_REVEAL", "false") == "true"
mask_extra = {n for n in os.environ.get("ENV_DUMP_MASK_EXTRA", "").split() if n}
stamp = os.environ.get("ENV_DUMP_TS", "")

# Substrings that mark a value as credential-bearing. SECRET is NOT here: see the
# header -- in this repo it names a Secrets Manager entry rather than holding one.
# "_PWD" rather than "PWD", or the shell's own PWD (the working directory) is
# masked and the report loses a genuinely useful line.
MASK_MARKERS = ("PASSWORD", "PASSWD", "_PWD", "TOKEN", "PRIVATE_KEY", "PRIVKEY",
                "CREDENTIAL", "AUTH", "PASSPHRASE")

# Shell built-ins that collide with the markers above but hold nothing sensitive.
NEVER_MASK = {"PWD", "OLDPWD"}

# Variables this script sets itself; noise in the report.
OWN = {"ENV_DUMP_FORMAT", "ENV_DUMP_REVEAL", "ENV_DUMP_MASK_EXTRA", "ENV_DUMP_TS"}

# Prefixes worth separating, most-asked-about first. The broker prefixes a
# resource's attributes with RESOURCE_, so that group is the whole question.
GROUPS = ["RESOURCE_", "BROKER_", "BRITIVE_", "AD_", "WINRM_", "AWS_"]


def is_secret(name):
    if name in mask_extra:
        return True
    if name in NEVER_MASK:
        return False
    return any(marker in name.upper() for marker in MASK_MARKERS)


def render(name, value):
    if reveal or not is_secret(name):
        return value
    digest = hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()[:8]
    return "<masked len={} sha256={}>".format(len(value), digest)


env = {k: v for k, v in os.environ.items() if k not in OWN}
names = sorted(env)

grouped = {g.rstrip("_"): {} for g in GROUPS}
grouped["other"] = {}
for name in names:
    for prefix in GROUPS:
        if name.startswith(prefix):
            grouped[prefix.rstrip("_")][name] = render(name, env[name])
            break
    else:
        grouped["other"][name] = render(name, env[name])

counts = {group: len(values) for group, values in grouped.items() if values}

# Context that is not an env var but answers the next question anyway.
context = {
    "argv": sys.argv,
    "cwd": os.getcwd(),
    "uid": os.getuid(),
    "gid": os.getgid(),
    "pid": os.getpid(),
    "python": sys.version.split()[0],
    "scan_output_path_set": bool(env.get("BROKER_INJECTED_SCAN_OUTPUT_PATH")),
}

if fmt == "keyvalue":
    # Britive parses "key: value" lines into response-template variables, so this
    # form is the one a template can display. Names first, for truncation.
    print("env_names: {}".format(",".join(names)))
    print("env_count: {}".format(len(names)))
    print("env_groups: {}".format(json.dumps(counts, sort_keys=True)))
    print("timestamp: {}".format(stamp))
    for group in list(grouped):
        for name in sorted(grouped[group]):
            print("{}: {}".format(name, grouped[group][name]))
    for key in sorted(context):
        print("ctx_{}: {}".format(key, context[key]))
else:
    payload = {
        # First key in the document, so a truncated read still shows it.
        "env_names": names,
        "env_count": len(names),
        "env_groups": counts,
        "timestamp": stamp,
        "env": {group: values for group, values in grouped.items() if values},
        "context": context,
    }
    print(json.dumps(payload, indent=2, sort_keys=False))
PYEOF

RC=$?

# Same content to STDERR: which stream a given broker action surfaces is not
# consistent, and one of the two will be visible.
if [ "$RC" -eq 0 ]; then
  printf '=== env diagnostic (also on STDOUT) ===\n' >&2
  printf 'env_names: %s\n' "$(env | cut -d= -f1 | sort | paste -sd, -)" >&2
  printf 'env_count: %s\n' "$(env | wc -l | tr -d ' ')" >&2
fi

if [ "$FAIL_AFTER" = "true" ]; then
  printf 'ENV_DUMP_FAIL=true, exiting non-zero so the broker records the output above\n' >&2
  exit 1
fi

exit "$RC"
