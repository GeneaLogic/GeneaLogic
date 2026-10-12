# Phase 1b — SQLite-driver spike: findings

> Throwaway investigation (XP "spike") to retire the one load-bearing decision in
> Phase 1b: **how GeneaLogicKit talks to SQLite, given the cross-platform contract.**
> Run 2026-06-09 on macOS (Xcode SDK) + stock `swift:6.1` Linux via Apple `container`.
> The `spike/` packages exist only to produce this result and are deleted once the
> driver lands in `GeneaLogicArchive`.

## The contract being tested (CLAUDE.md / ARCHITECTURE.md §10)

1. **Builds + runs on Linux via `scripts/linux-test.sh`** — i.e. on the *stock*
   `swift:6.1` image, with no modification to the harness.
2. **No Vapor dependency** anywhere in the package.
3. **Lean dependencies.** The index is a rebuildable cache, not an ORM problem.

## Decisive image fact

Stock `swift:6.1` ships the SQLite **runtime** (`libsqlite3.so.0.8.6`) but **not**:
- the dev header `/usr/include/sqlite3.h`,
- the unversioned `libsqlite3.so` link a linker needs for `-lsqlite3`,
- `pkg-config` entry or the `sqlite3` CLI.

So anything that `#include <sqlite3.h>` fails to build on the image until you
`apt-get install libsqlite3-dev` — which means editing the harness/image and, later,
the Vapor deploy image too.

## Results

| Driver | macOS | Linux (stock) | Linux (+libsqlite3-dev) | SQLite version | External deps |
|---|---|---|---|---|---|
| **Vendored amalgamation** | ✅ PASS | ✅ **PASS** | n/a | **3.46.1 everywhere** (we pin it) | none — one C file we own |
| System `libsqlite3` | ✅ PASS | ❌ header missing | ✅ (image edit) | whatever distro ships | none, but needs system header |
| **GRDB** 7.11.0 | ✅ PASS | ❌ `sqlite3.h not found` | ✅ (image edit) | mac 3.51.0 / linux 3.45.1 (**drift**) | GRDB + system header |

GRDB's default product is a wrapper over the **system** libsqlite3 (its `GRDBSQLite`
C shim does `#include <sqlite3.h>`), so it inherits the system-driver blocker exactly.

## Decision: vendor the SQLite amalgamation

The only option that satisfies criterion #1 **as written** (stock harness, no image
edit). It also uniquely gives us:

- **Version determinism** — the *same* SQLite (3.46.1) on macOS, Linux, and the
  future Vapor server. The system/GRDB paths already drift (3.51.0 vs 3.45.1),
  which would make checksum/index behavior platform-dependent.
- **Compile-flag control** — we set `SQLITE_ENABLE_FTS5` (full-text search over
  transcripts later), `SQLITE_THREADSAFE=1`, `SQLITE_DQS=0`; a system lib gives us
  whatever the distro built.
- **Zero external Swift dependency** — keeps the "no Vapor, lean deps" contract
  trivially, and there's no third-party Swift code in the trust boundary.

### Accepted costs

- ~8.7 MB `sqlite3.c` vendored into the repo (single file, in `spike/` now → moves
  to a `CSQLite` C target under `GeneaLogicArchive`).
- Clean builds compile it once (~3 s); cached thereafter.
- **We own updates**: bump the amalgamation when SQLite ships security fixes. Record
  the pinned version + source URL next to the file.
- The amalgamation emits benign warnings on macOS (FTS5 `MIN` macro ambiguity vs the
  SDK's `<sys/param.h>`); suppressible later, not a correctness issue.

## Next step (implementation, separate from this spike)

Add a first-party `CSQLite` C target (amalgamation + module map, the flags above) to
`GeneaLogicKit/Package.swift`, then replace the in-memory `ArchiveIndex` backing with
a `.index/index.sqlite` projection **behind the unchanged lookup API**, plus
`rebuildIndex()`. GRDB is reconsiderable later *only* if we ever vendor SQLite under
it — not worth the dependency for the query surface we have.
