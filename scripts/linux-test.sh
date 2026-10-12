#!/usr/bin/env bash
#
# Run a package's test suite on Linux, to verify the cross-platform contract
# (Foundation-only engine, compiles on Linux for Vapor — see CLAUDE.md).
#
# Uses Apple's `container` tool (https://github.com/apple/container) to run the
# official Swift Linux image natively on Apple Silicon. No Docker required.
#
# Usage:
#   scripts/linux-test.sh                          # swift test on GeneaLogicKit (default)
#   scripts/linux-test.sh build                    # swift build only
#   scripts/linux-test.sh test GeneaLogicCLI       # swift test on another package
#   PACKAGE_PATH=GeneaLogicCLI scripts/linux-test.sh
#   SWIFT_IMAGE=swift:6.3 scripts/linux-test.sh
#
# **Default-unchanged guarantee (judgment call):** the package path defaults to
# `GeneaLogicKit` so `scripts/linux-test.sh` with no args/env behaves exactly as
# before — it's referenced as-is in docs and the permissions allowlist. It can
# be overridden either positionally (`$2`, so it composes with the existing
# `$1` action argument and stays a single allowlisted invocation — no env-var
# prefix needed) or via the `PACKAGE_PATH` env var (`$2` wins if both are set).
# The CLI package depends on the engine via `.package(path: "../GeneaLogicKit")`;
# inside the container the repo root is mounted at `/work`, so running with
# `--package-path /work/GeneaLogicCLI` resolves `../GeneaLogicKit` to
# `/work/GeneaLogicKit` exactly as SwiftPM expects.
#
# The Linux build uses a separate --scratch-path per package
# (.build-linux/, .build-linux-<package>/) so Linux artifacts never collide
# with macOS .build/ or with each other.

set -euo pipefail

IMAGE="${SWIFT_IMAGE:-swift:6.3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-test}"
PACKAGE_PATH="${2:-${PACKAGE_PATH:-GeneaLogicKit}}"

# GeneaLogicKit keeps its original scratch directory name (.build-linux) so the
# default invocation is byte-for-byte unchanged; other packages get their own
# `.build-linux-<package>` directory.
if [[ "$PACKAGE_PATH" == "GeneaLogicKit" ]]; then
    SCRATCH_DIR=".build-linux"
else
    SCRATCH_DIR=".build-linux-$(basename "$PACKAGE_PATH")"
fi

# Ensure the container system is up (no-op if already running).
container system status >/dev/null 2>&1 || container system start

# Pull the image on first use (no-op if already present).
container image inspect "$IMAGE" >/dev/null 2>&1 || container image pull "$IMAGE"

exec container run --rm \
    -v "$REPO_ROOT:/work" \
    -w /work \
    "$IMAGE" \
    swift "$ACTION" --package-path "$PACKAGE_PATH" --scratch-path "/work/$SCRATCH_DIR"
