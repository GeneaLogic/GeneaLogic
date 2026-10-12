#!/usr/bin/env bash
#
# Stage a throwaway archive carrying all four shapes slice 50c reports, so the
# app half of the hand-test starts from the same state every time.
#
# Usage: scripts/stage-50c-handtest.sh [output-path]     # default /tmp/50c-hand.genea
#
# What it leaves on disk, and what each is for:
#
#   1. Person "John Smith" + a conflicted copy of his sidecar holding "Smyth-STALE"
#      → Conflicting copy. The Persons list must show **John Smith**.
#   2. Person "Mary Jones" whose sidecar was renamed away, so it is her only copy
#      → Record under the wrong name. Mary must be **absent** from the list, and
#        the row must offer the rename, never a deletion.
#   3. A duplicated artifact folder holding a STALE title
#      → Conflicting copy. The Artifacts list must show the **real** title.
#   4. `record (conflicted copy).json` beside a record.json — Dropbox's actual
#      file-level behaviour → Conflicting copy, **not** a stray.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-/tmp/50c-hand.genea}"
genea() { swift run --package-path "$ROOT/GeneaLogicCLI" genea "$@" 2>/dev/null; }

swift build --package-path "$ROOT/GeneaLogicCLI" >/dev/null 2>&1
rm -rf "$ARCHIVE"
genea create "$ARCHIVE" >/dev/null
genea add "$ARCHIVE" --title "1920 US Census – Smith" --source-tier census >/dev/null
genea add "$ARCHIVE" --title "Smith family portrait" --media-type image --source-tier compiled >/dev/null

JOHN="$(genea person add "$ARCHIVE" --given John --surname Smith | tail -1)"
MARY="$(genea person add "$ARCHIVE" --given Mary --surname Jones | tail -1)"

PERSONS="$ARCHIVE/conclusions/persons"
sed 's/Smith/Smyth-STALE/g' "$PERSONS/$JOHN.json" \
    > "$PERSONS/$JOHN (Ada's conflicted copy 2026-08-29).json"
mv "$PERSONS/$MARY.json" "$PERSONS/$MARY (Ada's conflicted copy 2026-08-29).json"

ARTIFACTS="$ARCHIVE/artifacts"
cp -R "$ARTIFACTS/1920-us-census-smith" "$ARTIFACTS/1920-us-census-smith 2"
sed -i '' 's/1920 US Census – Smith/STALE census title/' \
    "$ARTIFACTS/1920-us-census-smith 2/record.json"
sed 's/Smith family portrait/STALE portrait title/' \
    "$ARTIFACTS/smith-family-portrait/record.json" \
    > "$ARTIFACTS/smith-family-portrait/record (Ada's conflicted copy 2026-08-29).json"

genea reindex "$ARCHIVE" >/dev/null
echo "Staged $ARCHIVE — Mary is $MARY, John is $JOHN"
genea verify "$ARCHIVE" | cut -c1-120 || true
