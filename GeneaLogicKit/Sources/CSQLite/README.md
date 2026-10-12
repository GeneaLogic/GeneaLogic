# CSQLite

A first-party C target wrapping the **vendored SQLite amalgamation**, used by
`GeneaLogicArchive` for the `.index/index.sqlite` derived index
(ARCHITECTURE.md §5, §10 "Resolved" — SQLite driver).

- **Pinned version:** SQLite **3.53.4**
- **Source:** `https://sqlite.org/2026/sqlite-amalgamation-3530400.zip`
  (`sqlite3.c` + `sqlite3.h`, copied in verbatim)
- **Why vendored, not system/GRDB:** see
  [`docs/spikes/sqlite-driver.md`](../../../docs/spikes/sqlite-driver.md) — the
  stock Swift Linux image ships the SQLite *runtime* but not `sqlite3.h` (checked on both
  `swift:6.1` and `swift:6.3`), so anything that
  `#include <sqlite3.h>` (system lib, GRDB's default `GRDBSQLite` shim) fails
  to build on the unmodified Linux test harness. Vendoring also pins one
  SQLite version across macOS/Linux/the future Vapor server (the system/GRDB
  paths drift: 3.51.0 vs 3.45.1).

**Bump this for SQLite security fixes.** Run `scripts/update-sqlite.sh`: it
downloads the latest amalgamation, **verifies its SHA3-256 against the hash
sqlite.org publishes** in its machine-readable product data before any bytes
touch the repo, replaces `sqlite3.c` + `include/sqlite3.h` verbatim, and rewrites
the version/URL lines above. Then re-verify the cross-platform contract:
`swift test --package-path GeneaLogicKit` plus `scripts/linux-test.sh`.

We don't have to *remember* to do this: the **SQLite freshness** GitHub workflow
(`.github/workflows/sqlite-freshness.yml`) runs monthly, compares this pinned
version against upstream, and opens a tracking issue when we fall behind. (Bumping
is an engine change — the amalgamation is exactly what makes the Linux build work —
so it always goes through macOS + Linux verification.)

## Build flags (set in `Package.swift`)

- `SQLITE_ENABLE_FTS5` — full-text search over transcripts (future use; not
  yet wired into the index).
- `SQLITE_THREADSAFE=1` — SQLite's own mutexes on, even though
  `GeneaLogicArchive` additionally serializes all access through `Archive`'s
  `NSLock` (defense in depth, not a substitute for it).
- `SQLITE_DQS=0` — double-quoted strings are always string literals, never a
  fallback identifier (avoids a classic SQL-typo footgun).

The amalgamation emits some benign warnings on macOS (FTS5's `MIN` macro vs.
`<sys/param.h>`); not a correctness issue.
