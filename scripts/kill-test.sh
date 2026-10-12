#!/bin/bash
# Slice 65's out-of-process half: kill `genea` mid-write at random instants and
# check that every open afterwards succeeds and reports nothing new but
# `interrupted-write` or `unreferenced-file` — what the in-process property
# (WriteCutTests) asserts at every checkpoint, here with a real `kill -9` and
# nothing simulated. Findings the archive already had before the first kill (a
# `--from` copy of a real archive may carry some) are the baseline, not failures.
#
# Kills alternate between `genea add` (a new record: it can land or not, and
# leaves nothing stale) and `genea set-meta` on one artifact (a rewrite of a
# record the manifest already describes: the shape that leaves it suspect).
#
# Usage: scripts/kill-test.sh [--from SOURCE.genea] [ITERATIONS] [DEST.genea]
#   --from      copy SOURCE and work on the copy (SOURCE is never written);
#               without it, a fresh archive is created
#   ITERATIONS  default 200
#   DEST        default: a new temp path; printed at the end so you can open it
#
# A kill landing before the mutation starts or after it finishes is a clean
# run; the interesting ones land between the dirty marker and its clear. The
# window is a few milliseconds of a ~17 ms process, so the offset is drawn from
# 0–20 ms and a run reports how many kills left the archive suspect.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE=""
if [[ "${1:-}" == "--from" ]]; then
    SOURCE="$2"
    shift 2
fi
ITERATIONS="${1:-200}"
ARCHIVE="${2:-$(mktemp -d)/kill-test.genea}"

echo "Building the genea CLI…"
swift build --package-path "$ROOT/GeneaLogicCLI" >/dev/null 2>&1
GENEA="$(swift build --package-path "$ROOT/GeneaLogicCLI" --show-bin-path)/genea"

if [[ -e "$ARCHIVE" ]]; then
    echo "error: $ARCHIVE already exists; pass a new path" >&2
    exit 2
fi
if [[ -n "$SOURCE" ]]; then
    cp -R "$SOURCE" "$ARCHIVE"
    echo "Working on a copy of $SOURCE"
else
    "$GENEA" create "$ARCHIVE" >/dev/null
fi
echo "Archive: $ARCHIVE"

# The artifact `set-meta` rewrites, made before counting so it is not a killed add.
target=$("$GENEA" add "$ARCHIVE" --title "Rewritten by killed set-meta")
findings() { "$GENEA" verify "$ARCHIVE" 2>&1 | grep -E $'^[a-z-]+\t' || true; }
baseline=$(findings)
before=$("$GENEA" list "$ARCHIVE" | wc -l | tr -d ' ')
suspect=0
midway=0
for ((i = 1; i <= ITERATIONS; i++)); do
    if ((i % 2)); then
        "$GENEA" add "$ARCHIVE" --title "Killed add $i" >/dev/null 2>&1 &
    else
        "$GENEA" set-meta "$ARCHIVE" --artifact "$target" --notes "Killed rewrite $i" \
            >/dev/null 2>&1 &
    fi
    pid=$!
    sleep "0.0$(printf '%02d' $((RANDOM % 20)))"
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    # A kill that landed between the marker and its clear.
    compgen -G "$ARCHIVE/.index/*/dirty" >/dev/null && midway=$((midway + 1))

    # Every open must succeed…
    if ! "$GENEA" list "$ARCHIVE" >/dev/null 2>&1; then
        echo "FAIL: open failed after kill $i" >&2
        exit 1
    fi
    # …and report nothing new but an interrupted write or a stray copy.
    report=$(findings)
    worse=$(grep -vE $'^(interrupted-write|unreferenced-file)\t' <<<"$report" \
        | grep -vxF -f <(printf '%s\n' "$baseline") || true)
    if [[ -n "$worse" ]]; then
        echo "FAIL after kill $i:" >&2
        echo "$worse" >&2
        exit 1
    fi
    grep -q $'^interrupted-write\t' <<<"$report" && suspect=$((suspect + 1))
done

after=$("$GENEA" list "$ARCHIVE" | wc -l | tr -d ' ')
echo "OK: $ITERATIONS kills, every open succeeded; nothing new but interrupted-write or a stray."
echo "    $midway found a marker behind them; $suspect opens reported the archive suspect;"
echo "    $((after - before)) of the killed adds landed."
echo "    Open $ARCHIVE in the app to finish the hand-test."
