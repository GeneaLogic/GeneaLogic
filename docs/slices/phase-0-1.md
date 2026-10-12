# Phase 0 — Format spec & model (no app, no DB yet)

**Goal:** a written, versioned archive format spec and the Swift value types that
embody it, proven by round-trip tests.

- Write `GeneaLogicKit/schema/genealogic-archive-1.0.md` (the on-disk spec; ships inside every
  archive).
- `GeneaLogicModel`: `Artifact`, `FileEntry`, `PersonMention`, `Event`,
  `Location`, `Person`, `EvidenceLink`, `Relationship`, `Manifest` — all `Codable`,
  `Sendable`, Foundation-only.
- Decide JSON encoding details: key naming (DC/GEDCOM-X-aligned), date strategy
  (ISO 8601), stable key ordering for clean diffs.
- **Round-trip tests**: encode → decode → assert equality for every type; golden
  JSON fixtures checked into the repo.

**Exit criteria:** the schema doc and model agree; every record type round-trips;
fixtures are stable.

# Phase 1a — Archive engine ✅ DONE (merged to `main`, commit `d611c27`)

**Goal:** GeneaLogicKit can create and edit real archives on disk, headless, on
both macOS and Linux. **100 tests pass on macOS and Linux.**

Delivered in the `GeneaLogicArchive` target:
- `Archive.create`/`open` as an edited-in-place directory package; **atomic writes
  via POSIX `rename(2)`** (`AtomicIO`); streaming SHA-256 via swift-crypto; the
  schema spec copied into each new archive.
- Type-prefixed **UUIDv7** id minting (`IdentifierMinter`); the engine mints ids,
  callers never supply them.
- Artifact CRUD (`addArtifact`/`updateMetadata`/`removeArtifact`); file ops
  (`attachFile`/`replaceFile`/`detachFile`) implementing the full **§4.2.1
  file-naming invariant** (package-assigned `path` + `originalName`; case-fold +
  NFC uniqueness; sanitization; no silent overwrite; content-dedup report).
- Conclusions write path (`addPerson`/`addRelationship`/`link`); `manifest.json`
  maintenance (`commitManifest`); `verifyIntegrity()`; `repair()` (throwing stub).
- The **§5.1/§6.3 lookup surface** (`artifact(withID:)`, `artifacts(matching:)`,
  `artifacts(mentioning:)`, `artifact(withExternalIdentifier:)`, `artifact(atPath:)`,
  `artifacts(containingFileWithSHA256:)`, parallel `person…`), backed
  **provisionally by an in-memory `ArchiveIndex`** — the public surface is final.
- The **embedded-metadata seam** (`EmbeddedMetadata` + `MetadataExtractor` in the
  model, dependency-free); a no-op migration scaffold.

# Phase 1b — SQLite index + CLI ✅ DONE (branch `phase-1b-sqlite-spike`)

**Goal:** persist the derived index and ship a headless CLI; nothing in the public
lookup API changes. **6 CLI tests + 105 engine tests pass on macOS and Linux.**

- **SQLite-driver spike** — resolved to **vendor the SQLite amalgamation** (only
  option that builds on the stock `swift:6.1` harness; pins one SQLite version
  everywhere; zero external Swift deps). See `docs/spikes/sqlite-driver.md` and
  ARCHITECTURE.md §10 "Resolved".
- Replaced the in-memory `ArchiveIndex` with a `.index/index.sqlite` projection
  (`CSQLite` C target + `SQLiteDatabase` wrapper), kept in sync on every mutation,
  behind the **unchanged** lookup signatures. `open()` self-heals a
  missing/unopenable/schema-stale index; public `rebuildIndex()` regenerates it
  losslessly from the sidecars + conclusions.
- `GeneaLogicCLI` (separate top-level package over the engine, on
  swift-argument-parser): `genea create | add | attach | set-meta | verify |
  reindex | list | find` — `list`/`find` print `uid` + title for piping; `verify`
  exits non-zero on integrity problems.
- Logged two follow-ups for the sync/multi-writer era: index content-drift
  detection (§10.4) and cross-process concurrent-modification detection (§10.5).
- CI (macOS + Linux) still TODO — once a GitHub remote exists.

**Exit criteria (met):** create an archive and add artifacts with files via the CLI
on both OSes; `find` an artifact and use its `uid` to attach/edit; corrupt a file and
have `verify` catch it; delete `.index/` and rebuild it losslessly — all with the
SQLite-backed index.
