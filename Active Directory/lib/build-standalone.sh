#!/bin/bash
# ==============================================================================
# build-standalone.sh — inline lib/ad_common.sh into each permission script
# ==============================================================================
# The permission scripts source the shared library from the broker filesystem
# (/opt/britive-broker/lib/ad_common.sh, installed by v2/ecr/Dockerfile). That is
# the right arrangement for THIS deployment, where we control the image.
#
# Use this generator when you cannot: a broker whose image you do not build, a
# tenant where the scripts are pasted into the Britive console by hand, or a
# customer handover where a single self-contained file per permission is easier to
# audit. Each output file carries the library inline and needs nothing on disk.
#
# Usage:
#   ./build-standalone.sh [output-dir]      # default: ./standalone
#
# The generated tree mirrors the source directories it walks — permissions/,
# rotate/ and scans/ — so standalone/rotate/rotate-ad-account.sh is the
# self-contained twin of rotate/rotate-ad-account.sh. Outputs are derived
# artifacts: do not edit them; edit the sources and re-run.
#
# A script that does not source the library (rotate-env-diagnostic.sh) is copied
# through unchanged, so the output tree is always the complete set of files a
# broker without the library needs.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/lib/ad_common.sh"
SRC_DIRS=(permissions rotate scans)
OUT_DIR="${1:-${SCRIPT_DIR}/standalone}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -r "$LIB_FILE" ] || die "library not readable: ${LIB_FILE}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
for d in "${SRC_DIRS[@]}"; do
  [ -d "${SCRIPT_DIR}/${d}" ] || die "source directory not found: ${SCRIPT_DIR}/${d}"
done

log "==> library: ${LIB_FILE}"
log "==> sources: ${SRC_DIRS[*]}"
log "==> output:  ${OUT_DIR}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

count=0
copied=0
while IFS= read -r src; do
  rel="${src#"${SCRIPT_DIR}/"}"
  dest="${OUT_DIR}/${rel}"
  mkdir -p "$(dirname "$dest")"

  # Not every script uses the library. Copying it through keeps the output tree
  # complete, so a broker can take the whole directory and nothing is missing.
  if ! grep -q '^# Locate the shared AD helper library\.' "$src"; then
    cp "$src" "$dest"
    chmod +x "$dest"
    bash -n "$dest" || die "copied file has a syntax error: ${dest}"
    log "    ${rel} (no library dependency, copied verbatim)"
    copied=$((copied + 1))
    continue
  fi

  # Replace the loader block — from the AD_COMMON_LIB assignment through the
  # `. "$AD_COMMON_LIB"` line — with the library body, minus its shebang.
  #
  # Done in python rather than sed/awk because the substitution is multi-line and
  # the library contains regex metacharacters, backslashes and `&`, all of which
  # sed would reinterpret in a replacement.
  python3 - "$src" "$LIB_FILE" "$dest" <<'PY'
import re
import sys

src_path, lib_path, dest_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(src_path, encoding="utf-8") as fh:
    script = fh.read()
with open(lib_path, encoding="utf-8") as fh:
    library = fh.read()

# Drop the library's own shebang; the host script already has one.
library = re.sub(r"\A#!/bin/bash\n", "", library)

loader = re.compile(
    r"^# Locate the shared AD helper library\..*?^\. \"\$AD_COMMON_LIB\"\n",
    re.M | re.S,
)

if not loader.search(script):
    sys.exit(f"loader block not found in {src_path}; update build-standalone.sh")

banner = (
    "# ==============================================================================\n"
    "# GENERATED FILE -- DO NOT EDIT\n"
    "# ------------------------------------------------------------------------------\n"
    "# lib/ad_common.sh inlined by build-standalone.sh so this script runs on a broker\n"
    "# that does not carry the shared library. Edit the source under permissions/,\n"
    "# rotate/ or scans/ and re-run the generator instead of changing anything below.\n"
    "# ==============================================================================\n\n"
)

with open(dest_path, "w", encoding="utf-8") as fh:
    fh.write(loader.sub(lambda _: banner + library, script, count=1))
PY

  chmod +x "$dest"
  # Fail loudly here rather than shipping a broken blob to a tenant.
  bash -n "$dest" || die "generated file has a syntax error: ${dest}"
  log "    ${rel}"
  count=$((count + 1))
done < <(for d in "${SRC_DIRS[@]}"; do find "${SCRIPT_DIR}/${d}" -name '*.sh' -type f; done | sort)

log "==> ${count} inlined + ${copied} copied = $((count + copied)) script(s) written to ${OUT_DIR}"
log "    verify with: shellcheck -S style ${OUT_DIR}/*/*.sh"
