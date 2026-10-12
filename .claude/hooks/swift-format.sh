#!/bin/bash
# PostToolUse hook (Edit|Write on *.swift). Two jobs:
#   1. Format the edited Swift file in place (swift format).
#   2. Guard the cross-platform contract: warn if a file in a Linux-tested
#      package (GeneaLogicKit / GeneaLogicCLI) imports an Apple-only UI/crypto
#      framework. Those modules must compile on Linux (CLAUDE.md "Core is
#      Foundation-only"; checksums via swift-crypto, never CryptoKit). UI
#      frameworks belong only in GeneaLogicApp/.
#
# The guard is a fast local warning, not a hard gate — CI (the swift:6.3 Linux
# job) is what actually fails the build. It exits 2 with the warning on stderr
# so the assistant is reliably told to fix the leak before committing; the edit
# itself is not reverted. Formatting always still happens.

set -uo pipefail

input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"

[ -z "$file" ] && exit 0
case "$file" in
  *.swift) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

# 1. Format in place. Never blocks on failure.
swift format --in-place "$file" 2>/dev/null || true

# 2. Engine-purity guard — only for the Linux-tested packages.
case "$file" in
  */GeneaLogicKit/*|*/GeneaLogicCLI/*) ;;
  *) exit 0 ;;  # GeneaLogicApp/ (and anything else) may use UI frameworks.
esac

# Match `import AppKit`, `@preconcurrency import SwiftUI`,
# `import struct SwiftUI.Foo`, etc. — an optional leading attribute, the
# `import` keyword, an optional import-kind word, then a banned module.
banned='AppKit|UIKit|SwiftUI|Cocoa|Combine|CryptoKit'
matches="$(grep -nE \
  "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)?import[[:space:]]+([A-Za-z_]+[[:space:]]+)?($banned)\b" \
  "$file" 2>/dev/null || true)"

if [ -n "$matches" ]; then
  {
    echo "⚠️  Cross-platform-contract violation in a Linux-tested package:"
    echo "    $file"
    echo "    imports an Apple-only framework (must compile on Linux — CLAUDE.md):"
    printf '%s\n' "$matches" | sed 's/^/      /'
    echo "    UI frameworks belong only in GeneaLogicApp/; use swift-crypto, not CryptoKit."
    echo "    (Local warning — CI's swift:6.3 Linux job is the hard gate.)"
  } >&2
  exit 2
fi

exit 0
