# 56 — damage announces itself ✅

**Problem.** An artifact whose sidecar can't be read simply isn't in the list — from the
user's chair, indistinguishable from one that was never added. 55 made the archive open
and made the finding available, but the only way to *see* it is Verify Integrity, which
SHA-256s every tracked file. So the cheapest finding in the engine sits behind its most
expensive call, and the failure mode 55 set out to fix is still silent in the app. (Off
55's hand-test, 2026-08-10.)

**Layer.** Engine (one cheap read-only accessor) + app (a banner and placeholder rows).
**No format change**, no new detection — everything this surfaces is already recorded in
`.index/` by 55.

**Design forks:**

- **(a) The engine surface — a separate call, not a flag on `verifyIntegrity()`.** Add
  `standingFindings()`, returning a small struct: the unreadable-record paths and an
  `interruptedWriteSuspected` flag. **Recommend** this over a `verifyIntegrity(hashing:)`
  parameter, which would make the expensive default invisible at the call site and get
  chosen wrong. The struct rather than `[IntegrityReport.Issue]` is deliberate too: without
  hashing, "a write died" can only be said as a flag, not per-path (`.interruptedWrite`
  names a file, and naming one requires the comparison this call refuses to make). A type
  that can't express a claim it can't support is the point.
- **(b) Placeholders are read-only, and their one action is Reveal in Finder.** A skipped
  record has no index row, so all the app knows is its path — the slug for an artifact, the
  uid for a person, and no title or name, because that is exactly what failed to decode.
  So the row shows the path-derived identity and "Unreadable record". **Recommend no
  mutations from a placeholder** — not even delete: for an artifact we don't have an
  `ArtifactID` at all (it was inside the file), so every uid-addressed operation is
  unavailable by construction, and offering one would be a lie. Repairing broken JSON is a
  text-editor job, so Reveal in Finder is the honest affordance.
- **(c) Pinned at the top of the list, not in sort position.** There is no name to sort by,
  and burying damage mid-list is how it stays unnoticed. **Recommend** pinned, distinctly
  styled, above the normal rows.
- **(d) Which lists — artifacts and persons only.** Those are the two browsable lists an
  absent record disappears *from*. Relationships, links and dismissals have no list of
  their own, so they are covered by the banner and the integrity panel. That is the "as
  needed" scoping.
- **(e) Re-checked on 51's existing poll.** `externalChangeToken()` already runs every
  1–15s ([`ArchiveModel+ExternalChanges.swift`](../../GeneaLogicApp/GeneaLogicApp/Model/ArchiveModel+ExternalChanges.swift));
  the standing findings are a `SELECT` over a tiny table, so they ride it. **Recommend**
  this over open-only, so damage another process *commits* — the CLI reindexing, an agent
  writing — appears without waiting for a reopen.
  **What this does not do, stated because the first draft of this bullet implied
  otherwise** (found by 56's hand-test): the token is `PRAGMA data_version`, which moves
  only when a connection commits to the *index*. A sidecar corrupted on disk commits
  nothing, so the poll never fires — and `open()` won't catch it either, since a healthy,
  schema-current index is used without a walk. **This slice surfaces what the archive
  already knows; it does not go looking.** Until a rebuild runs, such damage is visible
  only to Verify Integrity (which does catch it — 49 put sidecar checksums in the
  manifest). Closing that without a hash pass is exactly **57**.
- **(f) The banner is dismissible per session, the rows are not.** One click must not
  permanently silence damage that is still there; it reappears on the next open or the next
  change. The placeholder rows stay regardless, which is what keeps (f) from mattering much.

**Out of scope:**

- **Any automatic hashing.** Tier 3 stays on demand — a full verify on every open is
  seconds-to-minutes of I/O and would fight a file provider on a synced archive.
- **The cheap stat sweep** → [**57**](57-the-cheap-sweep.md), below. Different mechanism, different price.
- **Repair or quarantine of the broken record** (→ **[59](59-repair-a-damaged-record-from-what-the-archive-still-knows.md)**;
  this said "→ 50" until 57, which was drift — 50 is sync conflict policy), and **CLI parity** for
  placeholder rows — `genea verify`/`reindex` already name skipped records.

**Verification.** Engine: `standingFindings()` reports the skipped record and does *not*
report checksum drift (that is the free/expensive line, and it's the thing a later
refactor would blur). App tests (`GeneaLogicAppTests`, from 52) over placeholder-row
construction from paths, for both lists. **Hand-test:** corrupt an artifact record and a
person record, open the app — banner, both placeholders pinned, Reveal in Finder lands on
the right file; repair one, and it returns to a normal row after a reindex.

**Shipped as specced** — all six forks. 668 engine + 141 CLI tests on macOS (665 on
Linux), 28 app tests. **Three departures, all found by running the app rather than the
tests:**

1. **The empty-state branch had to be handled explicitly.** An archive whose *only*
   artifact is unreadable took the `artifacts.isEmpty` path and rendered "No Artifacts
   Yet" — this slice's own bug, arriving through the empty state. Both lists now check
   for placeholders before showing an empty state.
2. **The row's headline and identity are on separate lines.** One line
   ("Unreadable record — deed-of-sale-1899") middle-truncates in a narrow sidebar to
   "Unreadable re…-of-sale-1899", losing the word that carries the meaning.
3. **The banner is on the bottom edge, not the top** (fork c said nothing about this, and
   the top looked obvious). A top `safeAreaInset` displaces the sidebar's `.searchable`
   field: the Artifacts list lost "Search artifacts" for as long as the banner was up.
   Only visible next to a healthy window.

**Then `/code-review` found three more, all fixed here:** the placeholder rows preempted
the "No Matches" state (they now sit out an active search — a record with no title can
neither match nor fail to match); the banner's dismissal was never reset, so damage
arriving afterwards was silent for the window's life; and `standingFindings()` reported an
index read failure as a clean archive — it throws now, and the app keeps its last known
findings rather than downgrading a warning because a read failed.

The app-test seam is also worth noting: `load()` is idempotent, so a test cannot "reopen"
a model to observe new findings. The suite drives the real path instead — a second
`Archive` handle as the competing writer, then 51's poll — which covers fork (e) properly
rather than approximating it.
