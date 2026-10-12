#!/bin/bash
# Build the sample archive (an invented family, slice 74b) to hand-test the Mac app
# against, so every hand-test starts from the same state.
#
# Usage: scripts/make-demo-archive.sh [output-path]
#   default output: /tmp/GeneaLogic-Demo.genea (replaced if it exists)
#
# It is `genea sample`, plus a verify and a listing. The app's welcome screen builds
# the same archive. Embedded EXIF (the portrait carries some) only surfaces as
# suggestions when a file is added *through the app* (ARCHITECTURE.md §6.4).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-/tmp/GeneaLogic-Demo.genea}"

echo "Building the genea CLI…"
swift build --package-path "$ROOT/GeneaLogicCLI" >/dev/null
# Run the built binary directly: no build noise to hide, so a failure's message shows.
GENEA="$(swift build --package-path "$ROOT/GeneaLogicCLI" --show-bin-path)/genea"
genea() { "$GENEA" "$@"; }

rm -rf "$ARCHIVE"
genea sample "$ARCHIVE"

echo "Verifying integrity…"
genea verify "$ARCHIVE" >/dev/null && echo "  integrity OK"

echo
echo "Done — contents:"
genea list "$ARCHIVE"
echo
echo "Open it in the app:  File ▸ Open Archive… → $ARCHIVE"
