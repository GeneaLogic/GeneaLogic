# 47 ✅ — cross-process write safety

**Problem.** Two GeneaLogic processes on one machine cannot write to the same
archive safely — the concrete case being the app open on an archive while an agent
drives `genea` against it. Three distinct failures: concurrent index writes get
`SQLITE_BUSY` **immediately** and throw, because the connection sets no busy timeout
([`SQLiteDatabase.swift:30`](../../GeneaLogicKit/Sources/GeneaLogicArchive/SQLiteDatabase.swift:30));
two edits to the same artifact silently lose one, since the sidecar write is guarded
only by a process-local `NSLock`; and if the index upsert fails *after* the sidecar
is written, the divergence is undetectable and never self-heals (`open()` rebuilds
only on missing/unopenable/schema-stale, never content drift).

**Layer.** Engine (`GeneaLogicArchive`) only — no model, no CLI, no app change.
**No format change:** the two new files both live under `.index/`, which is already
reserved, non-authoritative, and outside the manifest/index/integrity passes.
**Docs are in scope and not optional:** §2 principle 7 asserts the archive is
single-writer and that "multi-writer concurrency ... we do not have" — this slice
falsifies that sentence, and §10.5 goes from open to partly resolved (§10.4 stays
open; see *out of scope*).

**Design forks** (recommendations, to settle before building):

- **(a) Journal mode — WAL now, or busy timeout only? ✅ settled 2026-08-05: busy
  timeout only, WAL deferred to 48.** WAL genuinely fits this case (readers never block the writer, which
  is the app browsing while the CLI writes), but it adds persistent `-wal`/`-shm`
  files inside the package and needs shared memory — strictly worse under cloud sync
  and on network volumes. That is precisely the decision the *index-location* slice
  takes, and adopting WAL here would pre-commit it from the cheaper side. Busy
  timeout alone removes the failure actually being hit. **Cost of deferring:** a
  reader still blocks behind a writer's exclusive lock, so a long mutation briefly
  stalls the app's browse path.
- **(b) Unit of cross-process exclusion?** *Recommend an archive-level advisory lock
  (`flock(2)` on a lockfile), held for one whole mutation.* Per-artifact locks are
  finer-grained but every mutation ends in `commitManifest`, which is archive-wide,
  so they would serialize there anyway while adding a lock-ordering problem.
  Mutations are milliseconds.
- **(c) Where does the lockfile live?** *Recommend `.index/lock`* — a lock is exactly
  as machine-local and disposable as the index it sits beside, and `.index/` is
  already excluded from every manifest and integrity pass. At the package root it
  would surface in `verifyIntegrity()`'s unreferenced-file check and in any future
  BagIt conformance. **Implementation gotcha:** `rebuildIndex()` must not delete the
  lockfile out from under a held descriptor. **Resolve it (and the (f) sentinel)
  through `ArchiveLayout`, never as a hardcoded path** — 48 may move `.index/` out of
  the package, and both must relocate in one place.
- **(d) Block or fail?** *Recommend blocking up to ~5s, then throwing a typed
  `ArchiveError.archiveBusy`* carrying the holder's pid where obtainable, so the app
  can say "another process is writing this archive" rather than surfacing a generic
  failure. Indefinite blocking would hang the app's main actor.
- **(e) Do readers take the lock?** *Recommend no.* SQLite already gives
  committed-read consistency across processes, and a shared lock on every lookup
  would make browsing contend with the agent's writes for no correctness gain.
  **Consequence to document:** a read concurrent with a mutation may observe the
  pre-mutation state (sidecar written, index not yet) — stale, never torn, and
  bounded by that mutation's duration.
- **(f) How is sidecar/index divergence made detectable?** *Recommend a sentinel file*
  (`.index/dirty`) written before the index write and removed after it, so a crash or
  a failed upsert leaves it behind and the next `open()` rebuilds. It must be a
  **file, not an index `meta` row** — the failure it exists to catch is the index
  being unwritable. §10.4's generation marker is strictly more capable (it also
  catches out-of-band edits) but needs a home in the format; that is the sync slice's
  call, and this sentinel does not foreclose it.
- **(g) The stale in-memory `Manifest`.** *Recommend re-reading `manifest.json` at the
  start of each mutation, under the lock.* `files` already self-corrects via
  `recomputeManifestFiles`; this closes `name`/`updatedAt`, at one small file read per
  mutation.

**Out of scope** (each named with its owner):

- **Cross-*machine* sync safety.** `flock(2)` is unreliable on network filesystems and
  cannot serialize two machines against a cloud-synced folder. Two Macs writing one
  synced archive stays unsafe after this slice, and saying so plainly in §10.5 is part
  of the slice. → the **index-location + sync** slice.
- **Moving or sync-excluding `.index/`** → next slice; fork (a) waits on it.
- **Out-of-band edit detection** (§10.4's watermark / generation marker) — a
  hand-edited `record.json` still serves stale reads. → the sync slice.
- **App-side change notification.** The app will still show a stale list while the
  agent writes; the engine being correct does not fix the UI. → its own app slice.
- **Merging concurrent edits.** This slice makes two writers take turns, not merge.

**Verification.**

- Unit: the busy timeout is set on every connection; lock acquire/release around a
  mutation; `archiveBusy` thrown on timeout; the sentinel is absent after a clean
  mutation and present after an injected index failure, with `open()` rebuilding from
  it and the sidecar's data surviving.
- **Real multi-process tests** — the honest ones cannot run in-process: spawn N
  concurrent `genea` invocations against one archive and assert every write landed.
  They need the built CLI binary, so they live in the **CLI package's** tests.
- **The invariant that matters, asserted directly:** after any interleaving, every
  sidecar parses and `rebuildIndex()` reproduces the index — the sidecars are
  authoritative, so that is the real contract, and it is a stronger check than any
  per-operation assertion.
- **Linux-verified** via `scripts/linux-test.sh` — not a formality here: `flock(2)`
  semantics and `errno` differ between Darwin and Glibc, and this is the first
  syscall-level concurrency code in the package.
- **Hand-test:** open the app on a *copy* of the real archive, run a shell loop of
  `genea` writes against it, confirm no errors and no lost writes. The app not
  *showing* them until refreshed is expected, not a bug — that's the notification
  slice.

**If this is too big for one slice**, the natural cut is (f) + (g) — divergence
detection and the manifest re-read — into a **47b**, leaving 47 as mutual exclusion
alone. They are specced together because busy timeout makes a failed index write rare
and the sentinel handles the residue; shipping the lock without detection leaves the
silent-divergence hole open. *Not needed — (a)–(g) all shipped in one slice; see
[SLICE-LOG](../SLICE-LOG.md).*
