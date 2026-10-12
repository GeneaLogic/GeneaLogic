# 60 — the index knows whether it is current

**Problem.** The index has four rebuild triggers — missing, unopenable, schema-stale,
and 47's `.index/dirty` sentinel — and every one of them answers *is this database
usable?* None answers *does it reflect the files on disk?* So records that changed
without this engine's involvement — delivered by cloud sync from another machine,
merged in by `git`, restored from a backup — leave all four satisfied, and `open()`
serves stale reads from a healthy index indefinitely.

***Corrected during implementation, 2026-08-23:** this first read "a hand edit, a
`git merge`, a sync delivery", and **a bare hand edit is not in the set** — editing one
`record.json` in place does not touch `manifest.json`, so the witness cannot move. The
set is changes that arrive **with the manifest that describes them**, which is every one
that matters for 48. The exclusion is right rather than a shortfall: a file whose bytes
disagree with the checksum the manifest recorded is **suspect**, equally consistent with
bit rot — 49 deliberately reports it instead of believing it and 58 refuses to overwrite
it, so rebuilding the query surface from it automatically would launder exactly what
those two exist to catch. The witness adopts what is safe to adopt automatically;
`verifyIntegrity()` + `rebaseline()` keep the rest, and the boundary is now a test rather
than a sentence.*

ARCHITECTURE §10.4 has carried this since
Phase 1b; 47 narrowed it to drift the engine did not cause, 49 made that drift
**reportable** by `verifyIntegrity()`, and this slice makes it **self-correcting**.
It is §10.4's option (a) — the cheap watermark — un-parked, and it is the gate on
[48](48-50-cross-machine-sync.md): under
per-machine index directories a cross-machine handoff *is* this case, every time.

**Layer.** Engine (`GeneaLogicArchive`) + one call site in the app; no model, no CLI.
***Corrected during implementation:** this said "engine only, no app change", which could
not have been true — the hand-test below needs the app to act, and `reconcileIfStale()`
needs a caller. It is ~15 lines in `ArchiveModel`'s existing poll, **off the main
actor**, because the check can end in a full rebuild and running that inline would put
back the freeze slice 52 took out. The CLI needs nothing: every `genea` invocation opens
the archive fresh, and the open path already reconciles.* **No format change**, and that is the
slice's central finding rather than an absence: §10.4 wrote option (b) as needing "a
home in the format", and **slice 49 already built one**. `manifest.files` now carries
an entry for every `record.json` and every `conclusions/**` record, so the manifest
already changes whenever anything the index derives from changes. What is new is only
that the index records *which* manifest state it was built from, in its own `meta`
table — machine-local, rebuildable, outside the manifest and every integrity pass.

**Design forks** (recommendations, to settle before building):

- **(a) What is the witness?** *Recommend a digest over `manifest.files`* — each
  entry's `path`, `sha256` and `byteLength`, in the manifest's own order — written to
  the index `meta` table at every commit and at the end of every rebuild. **Not
  `manifest.updatedAt`**: it is `ISO8601DateFormatter` output at second resolution
  ([Archive.swift:215](../../GeneaLogicKit/Sources/GeneaLogicArchive/Archive.swift:215)),
  so two writes in one second are indistinguishable. **Not the manifest file's own
  sha256**: that also moves when `name` changes, which the index does not derive from,
  and a false positive here costs a full rebuild. **Not a monotonic counter** (§10.4's
  option (b)): it needs a new field in the format, and two machines bumping
  independently produce the same value from different states — strictly *less*
  discriminating than a content digest for the case this exists for. Treat option (b)
  as **superseded, not deferred**.
  **The completeness claim is a test, not a sentence:** every index table's source
  must be a manifest-covered path — `artifact`/`place` and `file` from
  `artifacts/*/record.json` plus payload; `person`, `relationship`, `link`,
  `dismissal` from `conclusions/**`; `unreadable_record`/`orphaned_record` from the
  same walk. If that ever stops being true, this test fails before the staleness does.
- **(b) When is it checked?** *Recommend `open()` **and** the poll 51 already runs.*
  `open()` alone is not enough and the reason is the whole of 51: the app holds one
  `Archive` for the window's lifetime, so an archive that goes stale after opening
  never re-opens.
- **(c) What does it cost?** *Recommend a two-stage gate:* `stat` `manifest.json`
  (size + mtime) first, and read-and-digest only when it moved. the real archive's manifest is
  15.6 KB for 90 entries (~175 B/entry), so 10,000 entries is ~1.7 MB — too much to
  digest on a 1 s poll, and on the overwhelmingly common unchanged tick there is
  nothing to digest at all. Record the stat beside the digest. **51 rejected an mtime
  poll** because the manifest's mtime moves for our own writes too; that objection
  does not carry here — recording the stat *at commit time* makes our own write look
  local by construction, and the mtime is a gate on a definitive check rather than the
  answer itself.
- **(d) What happens on a mismatch?** *Recommend a full `rebuildIndex()`.* Incremental
  re-read of only the entries whose checksum moved is the obvious optimization and is
  deliberately **not** taken: it needs a per-record before/after diff, and getting it
  wrong yields a silently partial index — precisely the failure this slice exists to
  remove. Measure the rebuild on the largest archive to hand; if it is bad, incremental
  becomes its own slice with a number.
  **✅ Measured 2026-08-23, and incremental is not needed — the escape hatch stays
  shut.** The real archive (21 artifacts) was far too small to answer it, so this is synthetic:
  **500 artifacts → 43 ms rebuild, 2,000 → 177 ms**, linear at ~88 µs/artifact, which
  puts a 10,000-artifact archive under a second. It runs off the main actor and **once
  per cross-machine handoff**, not per poll. The number that makes that safe is the
  other column: **a no-op poll costs 0.02 ms** at both sizes — fork (c)'s `stat` gate
  doing exactly its job, since the digest it guards would be 91 KB and 369 KB of
  manifest respectively. Revisit only if an archive an order of magnitude past this
  appears, and note the cost that would bite first is the *manifest write per
  conclusion edit*, which is 49 fork (c)'s escape hatch, not this one.
- **(e) The wrinkle that carries the slice's risk: sync is not atomic across files.**
  A machine can receive the new `manifest.json` **before** the new `record.json`.
  Rebuilding then records a witness for a half-delivered set, and because the manifest
  does not change again when the sidecar finally lands, **nothing re-triggers** — stale
  permanently, which is worse than the bug being fixed. *Recommend: rebuild from what
  is there, but record the new witness only when the delivery looks complete* — 57's
  cheap sweep, every manifest entry present and `stat`ing to its recorded
  `byteLength` — and otherwise leave the old witness in place so the next check
  re-fires. **Never hash on this path:** 57's out-of-scope finding is that hashing a
  dataless file materializes it, so a completeness check that hashed would turn every
  poll into a whole-archive download. Size-only misses a same-size partial delivery,
  the same limit 57 already documents and accepts. **And back off** rather than
  rebuilding on every tick while a delivery is in flight.
- **(f) Does this change what `.index/dirty` means?** *Recommend no, and keep them
  distinguishable.* The sentinel says *our* write died mid-flight; the witness says
  *the files no longer match what we indexed*. Both can be set at once and they mean
  different things. In particular a witness-driven rebuild must **not** clear
  `hasUnresolvedInterruptedWrite` — only `rebaseline()` resolves that (49's rule).

**Out of scope** (each named with its owner):

- **Where the index lives** → [48](48-50-cross-machine-sync.md),
  which depends on this and must not be built first.
- **Conflict policy** → 50. This slice makes a machine *notice* another machine's
  writes; it does not make two concurrent writers safe. A witness change cannot
  distinguish "they wrote and I did not" from "we both wrote and one of us lost".
- **Cross-machine mutual exclusion** — impossible over a store-and-forward sync
  channel; see 48–50's placeholder for why the flock does not extend.
- **Incremental rebuild** → (d), if the measurement asks for it.
- **§10.4's option (b) generation marker** — superseded by (a), not parked.

**Verification.**

- Engine: deliver a record **and its manifest** from a second copy of the archive
  (standing in for the other machine) → the index reflects the change on reopen *and* on
  a live handle, with no explicit `rebuildIndex()`; the same for a conclusion added and
  one deleted. **The boundary is asserted in the same suite:** a bare hand edit with no
  manifest is *reported* by `verifyIntegrity()` and deliberately not adopted. **Assert a rebuild *count*, not just correctness** — a slice that rebuilds
  on every open passes a correctness-only test trivially — so: our own writes move the
  witness without triggering a rebuild, and an unchanged archive rebuilds zero times
  across many polls. **(e) injected directly:** a manifest describing a sidecar not yet
  on disk leaves the old witness in place and the next check re-fires. `.index/dirty`
  and a witness mismatch set together stay separately reportable, and the rebuild does
  not clear the sentinel.
- The (a) completeness test: table by table, every index source is a manifest-covered
  path.
- **Linux-verified** via `scripts/linux-test.sh` for engine and CLI — this is core.
**`/code-review` found seven, and three were the same root cause** (2026-08-23, all
fixed here):

- **A witness-driven rebuild must adopt the delivered manifest, not recompute it.**
  Routing the reconcile through the mutation chokepoint meant its closing
  `commitManifest` rebuilt `manifest.files` *from the freshly rebuilt index* — so
  every entry whose file had not arrived yet was **deleted from the one document that
  says it is expected**. A staleness poll destroyed the delivered manifest. It also
  made fork (e) unable to fire: the completeness check then inspected a manifest
  scrubbed of exactly the missing files, blessed the witness, and left a newly
  delivered record invisible permanently. The fork (e) test as first written missed
  this because it covered an *update*, whose entry survives by carry-forward; a
  **new** record has no entry to carry. Adopting now skips recompute and write
  entirely.
- **A mutation may only certify what it was entitled to certify.** Every commit
  recorded a witness unconditionally, so one unrelated `addPerson` after a delivery
  stamped the un-noticed stale index "current" — and it stayed that way through any
  number of reopens, with `verifyIntegrity()` reporting nothing. The bless is now
  conditional on the index having matched the manifest *before* the mutation, which
  is one `stat` in the common case.
- **Fork (e)'s back-off was specced and not built.** A cleared witness makes the
  archive read as stale unconditionally, so the app's 1 s poll took the archive lock
  and walked every sidecar every tick for as long as one large file was in flight.
  Now keyed on the manifest's stamp — progress resets it, repeated failure on the
  same manifest doubles from 1 s to 30 s.
- **Stamp before reading, not after.** `of()` digested a manifest read earlier and
  stamped the file afterwards; on the open path that gap spans a whole rebuild, so a
  manifest delivered mid-rebuild was stamped but never digested and the cheap gate
  said "unchanged" for ever. The ordering is now in the signature
  (`of(_:stampedBefore:)`), plus a `read(from:)` that does it correctly in one call.
- Two doc comments still claimed a bare hand edit is adopted, contradicting the
  correction above and the test; one doc comment was orphaned by a new `// MARK:`.
- **And one the review did not find, caught while fixing:** `adoptingDeliveredManifest`
  is set inside the mutation body and consumed by `commitManifest`, which a throw
  never reaches — so a reconcile whose rebuild failed would have left the flag set and
  the *next* mutation would have silently skipped writing `manifest.json`. Cleared in
  `withState`'s `defer` now, like `authoredWrites`.

**The hand-test then found an eighth, and it needed a fork the spec had not asked**
(2026-08-23, folded in on the user's call). Mid-delivery — B's manifest arrived, B's
record still in flight — `verifyIntegrity()` reported `size-mismatch` +
`checksum-mismatch`, 57's never-cry-wolf banner would have said *"1 file is missing"*
for the whole of a large download, and 58's drift guard refused the edit while
**advising a `rebaseline` that discards the incoming version**: run, it blessed the
stale local bytes, and the record then landed as reported corruption rather than an
adoption. So a third classification, `.awaitingDelivery`, alongside
`.checksumMismatch` and 49's `.interruptedWrite`, plus
`ArchiveError.recordAwaitingDelivery` whose advice is *wait*, and a banner that stays
silent by name rather than by falling through a `default`.

**The signal took two attempts, and the first was circular.** "The index has no
witness" looked like the natural reading of *a delivery is in flight* — but
`manifestDeliveryLooksComplete` is false for **any** mismatch, which is exactly what
`verifyIntegrity()` reports, so clearing the witness on damage made every damaged
archive claim to be receiving one. (Caught by 49's own regression test: a rotted
payload file on an archive with a dirty sentinel.) The fix is to **keep the last
settled witness instead of clearing it** — which serves fork (e) equally well, since a
witness that still disagrees with the disk re-fires the next check — and to define the
signal as *the manifest on disk is not the one we last settled*. **Corruption does not
change `manifest.json`**, so it leaves the settled witness matching and reads as
damage; a manifest that differs from the settled one can only have come from
elsewhere. The one exception is an archive with no witness at all — a pre-60 archive's
first open — where there is no previous state to differ from, so whatever is on disk
becomes the baseline and a fault in it reports as damage, exactly as before this slice.

**A second `/code-review` found five more** (2026-08-23, all fixed here). Two are the
same two mistakes as the first round, in the places the first round's fixes did not
reach — which is the lesson worth keeping:

- **The manifest recompute drops an in-flight entry on the *ordinary* mutation path
  too.** The first review fixed the reconcile path only; every other mutation still
  recomputes, `authoredPaths` still reads the index, and a delivered-but-unarrived
  record is still absent from it — so one unrelated `addArtifact` deleted the entry,
  the rewritten manifest then looked complete, the next reconcile settled it, and the
  record was lost when it landed. Fixed by naming those paths explicitly
  (`awaitedPaths`), the same shape as 55's rule for unreadable records, **gated on a
  delivery actually being in flight** so ordinary deletion still drops its entry.
- **The write path stamps after writing**, inverting the ordering `of(_:stampedBefore:)`
  was introduced to enforce — the archive lock excludes other GeneaLogic processes, not
  a sync daemon. Now the stamp is kept only if the file's size still matches the bytes
  we wrote. Residue accepted and written down: a same-length overwrite inside that
  window still passes, and closing it costs a re-read per mutation.
- **The Verify panel rendered blank for an arrival.** Its three severity filters were
  hand-written, so `.arriving` matched none, and an archive whose only findings were
  arrivals is not `isClean` — it skipped "Archive Is Intact" and drew a `List` with
  zero sections, on the one surface the banner deliberately stays silent in favour of.
  Fixed structurally rather than by adding a fourth filter: sections come from a table,
  `Severity` is `CaseIterable`, and an app test holds the table to every case, so the
  next severity fails a test instead of rendering nothing.
- **The app's reconcile task adopted a token from an archive it may no longer be
  showing** — `load()` can land mid-rebuild — so it now checks handle identity first.
- Doc drift in four places still describing the rejected "clear the witness" signal.

- **Hand-test** (revised with the problem statement): on a *copy* of the real archive,
  make a **second** copy, edit a record in the second with `genea`, then copy that record
  and `manifest.json` over the first — the two-machine delivery, by hand. With the app
  open on the first copy, the list updates on its own within a poll, with nothing run by
  hand. ✅ Done 2026-08-23, driven end to end against a copy of the real archive; fork (d)'s
  measurement is recorded above.
  **Two things it taught, neither of them a defect in the mechanism.** A size mismatch
  rendered through `.byteCount` printed *"Expected 2 kB, found 2 kB"* — manifest
  mismatches are usually small, and rounding collapsed both numbers, so a real finding
  read as a broken app; exact bytes are now used whenever the friendly forms would
  collide. And **delivering records without their manifest is not a delivery** — it is a
  bare out-of-band edit, which the engine is right to report as corruption and right to
  refuse to adopt. The test rig had to learn that too: its copy predicate compared
  *sizes* to decide what had already arrived, and a same-length edit was skipped — the
  same size-only shortcut the engine takes deliberately (hashing a dataless file
  materializes it) and the rig had no excuse for.
