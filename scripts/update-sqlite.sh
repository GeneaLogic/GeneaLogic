#!/usr/bin/env bash
#
# Refresh the vendored SQLite amalgamation (GeneaLogicKit/Sources/CSQLite) to the
# latest upstream release — primarily so we pick up security fixes. We vendor the
# amalgamation (not a system lib) for cross-platform version determinism; see
# Sources/CSQLite/README.md and docs/spikes/sqlite-driver.md.
#
# Supply-chain integrity: the downloaded zip's SHA3-256 is verified against the
# hash sqlite.org publishes in its machine-readable product data BEFORE any bytes
# touch the repo. A mismatch aborts without modifying anything.
#
# Usage:
#   scripts/update-sqlite.sh                 # update to the latest published release
#   scripts/update-sqlite.sh --version 3.53.3  # require a specific version (must be the
#                                              # current published one — older releases
#                                              # aren't listed in product data)
#   scripts/update-sqlite.sh --check         # report current vs. latest, change nothing
#
# After updating, re-verify the cross-platform contract:
#   swift test --package-path GeneaLogicKit  &&  scripts/linux-test.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSQLITE_DIR="$REPO_ROOT/GeneaLogicKit/Sources/CSQLite"
HEADER="$CSQLITE_DIR/include/sqlite3.h"
README="$CSQLITE_DIR/README.md"
DOWNLOAD_URL="https://sqlite.org/download.html"
BASE_URL="https://sqlite.org"

PIN_VERSION=""
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) PIN_VERSION="${2:?--version needs a value}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need curl; need unzip; need python3

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching product data from $DOWNLOAD_URL …"
curl -fsSL --max-time 60 "$DOWNLOAD_URL" -o "$tmp/download.html"

# The amalgamation row in sqlite.org's CSV product block:
#   PRODUCT,<version>,<relpath>/sqlite-amalgamation-<digits>.zip,<bytes>,<sha3-256>
row="$(grep -E '^PRODUCT,[^,]+,[^,]*sqlite-amalgamation-[0-9]+\.zip,' "$tmp/download.html" | head -1 || true)"
[ -n "$row" ] || { echo "could not find the amalgamation row in product data" >&2; exit 1; }

latest="$(printf '%s' "$row" | cut -d, -f2)"
relurl="$(printf '%s' "$row" | cut -d, -f3)"
sha3_expected="$(printf '%s' "$row" | cut -d, -f5)"

current="$(grep -E '#define SQLITE_VERSION ' "$HEADER" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo unknown)"
echo "Vendored: $current   Upstream latest: $latest"

if [ -n "$PIN_VERSION" ] && [ "$PIN_VERSION" != "$latest" ]; then
  echo "Requested --version $PIN_VERSION, but the current published release is $latest." >&2
  echo "This script can only fetch the latest (older releases aren't in product data)." >&2
  exit 1
fi

if [ "$current" = "$latest" ]; then
  echo "Already up to date ($latest). Nothing to do."
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "Update available: $current → $latest. Run without --check to apply."
  exit 1
fi

zip_url="$BASE_URL/$relurl"
echo "Downloading $zip_url …"
curl -fsSL --max-time 120 "$zip_url" -o "$tmp/amalgamation.zip"

echo "Verifying SHA3-256 against published product data …"
sha3_actual="$(python3 -c 'import hashlib,sys; print(hashlib.sha3_256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/amalgamation.zip")"
if [ "$sha3_actual" != "$sha3_expected" ]; then
  echo "SHA3-256 MISMATCH — refusing to vendor bytes that don't match sqlite.org." >&2
  echo "  expected: $sha3_expected" >&2
  echo "  actual:   $sha3_actual" >&2
  exit 1
fi
echo "  ok: $sha3_actual"

echo "Extracting …"
unzip -q "$tmp/amalgamation.zip" -d "$tmp/unzip"
src_dir="$(dirname "$(find "$tmp/unzip" -name sqlite3.c | head -1)")"
[ -f "$src_dir/sqlite3.c" ] && [ -f "$src_dir/sqlite3.h" ] \
  || { echo "amalgamation is missing sqlite3.c/sqlite3.h" >&2; exit 1; }

cp "$src_dir/sqlite3.c" "$CSQLITE_DIR/sqlite3.c"
cp "$src_dir/sqlite3.h" "$HEADER"

# Rewrite the README's pinned-version and source-URL lines to match.
python3 - "$README" "$latest" "$zip_url" <<'PY'
import re, sys
path, version, url = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = re.sub(r'(\*\*Pinned version:\*\* SQLite \*\*)[0-9][0-9.]*(\*\*)', rf'\g<1>{version}\g<2>', s)
s = re.sub(r'`https://(?:www\.)?sqlite\.org/[^`]+`', f'`{url}`', s, count=1)
open(path, "w").write(s)
PY

echo
echo "Vendored SQLite updated: $current → $latest"
echo "Now verify both platforms:"
echo "  swift test --package-path GeneaLogicKit  &&  scripts/linux-test.sh"
