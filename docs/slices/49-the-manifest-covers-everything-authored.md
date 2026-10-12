# 49 — the manifest covers everything authored ✅

**Problem.** `verifyIntegrity()` cannot see damage to the archive's most valuable data.
`manifest.files` lists artifact payload files plus the schema spec, so bit rot in a
preservation master — the *most* reproducible thing here, with a physical original and a
backup behind it — is caught, while bit rot in `artifacts/*/record.json` or
`conclusions/**/*.json` — the transcriptions, mentions, facts, provenance, and the whole
conclusion layer, none of it re-derivable from anything — is invisible. The same blindness
is §10.4's out-of-band-edit gap seen from the other side: a sidecar hand-edited or
delivered by sync leaves no trace the engine can report. This is §10 open question 4's
option **(c)**, un-parked. (Raised by a reviewer agent 2026-08-08; the gap was already
documented, the design below is what it takes to close it without making things worse.)

**Layer.** Engine + **format** (manifest scope, and one revision to a Phase 1a settled
decision). CLI and app get display only. The format part settles first, in both spec
copies, per `SchemaSpecTests`.

**Design forks** (settled 2026-08-08):

- **(a) Derived or carried forward? ✅ carried forward — this is the whole slice.**
  `manifest.files` is fully derived today: [`recomputeManifestFiles`](../../GeneaLogicKit/Sources/GeneaLogicArchive/Archive.swift:499)
  rebuilds it every commit. That is safe for payload files *only* because their
  authoritative hash is authored into `record.json`'s `files[]` at attach time and merely
  copied through the index — recompute never re-hashes the file, so it cannot launder
  corruption. A sidecar has no second copy of its own hash, so the naive version of (c)
  **erases the evidence it exists to preserve**: rot gets re-hashed, the manifest is
  rewritten with the rot's hash, and the next verify is clean. Rule, therefore:
  **absent entry → mint from disk; present entry → carry forward verbatim; never re-hash
  a present entry.** Hashes are minted at write time from the bytes `AtomicIO.writeJSON`
  already holds ([AtomicIO.swift:88](../../GeneaLogicKit/Sources/GeneaLogicArchive/AtomicIO.swift:88)) —
  O(1) per mutation, no re-walk. This makes `manifest.files` **partly authoritative
  rather than wholly derived**, which is the invariant change to write into spec §5 and
  into ARCHITECTURE's settled *Manifest scope* bullet.
- **(b) Scope: sidecars only, or conclusions too? ✅ both** (user's call, 2026-08-08). If
  the argument is "hand-authored metadata is the irreplaceable part," `conclusions/**`
  qualifies exactly as much as `record.json`; covering one and not the other closes half
  the gap and leaves the more-edited half open.
- **(c) `manifest.updatedAt` semantics — ✅ revised.** Phase 1a settled that conclusions
  writes do not bump it. Under (b) they now change `files`, so the rule becomes **bumped
  whenever `files` changes**, and the old bullet is edited rather than left to contradict
  the code. Consequence to accept knowingly: every conclusion write now also writes
  `manifest.json`, which it never did. Recompute stays cheap (carry-forward does no
  hashing), so the cost is one atomic write of an N-entry file per conclusion edit. **A
  separate `manifest-metadata.json` was the alternative** — rejected as splitting the
  one surface preservation tooling is supposed to read (§3) — but if the write cost
  measures badly at scale it is the fallback, so keep entry construction in one function.
- **(d) Blessing a legitimate edit ✅ an explicit op, never automatic.** Spec §5.1 blesses
  hand-editing a sidecar then calling `rebuildIndex()`; under this slice that edit now
  reports `checksumMismatch` — correct, and the point — but with no way to say "current
  disk is the truth" the report stays dirty forever. So: a `rebaseline` operation
  (engine + `genea` verb + app affordance) that re-mints every entry from disk. It must
  **never** fire from `open()` or from a normal commit, or (a)'s laundering is back
  through the side door. `repair()` stays the stub it is.
- **(e) The crash window ✅ reported as its own issue kind.** Sidecar written, manifest
  not yet → a stale hash indistinguishable from rot. 47's `.index/dirty` sentinel already
  brackets the mutation, so when it is set on open, a mismatch is reported as
  `.interruptedWrite(path:)` rather than `.checksumMismatch` — suspect, not corrupt. It
  does not record *which* record was in flight, so this is a classification, not a repair;
  the user is told which file and that a write died, and `rebaseline` is the resolution.
- **(f) Compatibility ✅ additive, no `schemaVersion` bump.** New entries use the existing
  `path`/`sha256`/`byteLength` shape; an old reader verifies them fine. The rule to write
  down: **a manifest with no sidecar entries means *unverified*, never *tampered*** — a
  new reader must not report them missing. Migration needs no flag or upgrade pass: (a)'s
  absent-→-mint rule fills an old archive in as records are touched.

**The parts where the bugs will be:** carry-forward means entries no longer fall out of a
recompute, so **deletion and re-slugging must move or drop the entry explicitly** —
`removeArtifact`, trash/restore, and any path change that a re-derived manifest handled
for free. Test each directly.

**Out of scope:**

- **Fixing stale *reads*.** This slice makes drift *reportable*, not self-healing; a
  hand-edited sidecar still serves stale query results until `rebuildIndex()`. Hashing
  everything at `open()` is the wrong price for that — it wants §10.4's cheap
  mtime/count watermark, option (a), which stays parked. **The 48–50 placeholder's
  wording conflates the two**; it gets corrected to say 49 is detection only.
- **`repair()`** — unchanged stub (Phase 2+ taxonomy work), and `rebaseline` is
  deliberately not spelled "repair".
- **An unreferenced-file sweep over `conclusions/`.** `findUnreferencedFiles` keeps its
  current scope; the `record.json` exemption there becomes redundant-but-harmless, since
  those files are now covered by the per-entry checks (same as `schema/`).
- **BagIt-literal conformance** (§10 open question 3) and **conflict policy** (→ 50).

**Verification.**

- Engine: rot a `record.json` and a conclusion file → each reports `checksumMismatch`;
  hand-edit then `rebaseline` → clean; **the laundering regression test** — mutate a
  *different* artifact after rot and assert the rotted file's manifest entry is unchanged
  and still mismatching; `.index/dirty` set + mismatch → `.interruptedWrite`; delete,
  trash/restore, and re-slug each leave no orphan or stale entry; an old manifest with no
  sidecar entries verifies clean and fills in on next write.
- `SchemaSpecTests` for both spec copies; `scripts/linux-test.sh` for engine and CLI —
  this is core, so Linux is a hard gate.
- CLI `genea verify` prints the new issue kinds; `IntegrityReportSheet` displays them.
- **Hand-test:** on a *copy* of a real archive, edit a `record.json` in a text editor,
  run verify, see it named; rebaseline; verify clean. Then measure `manifest.json` size
  and conclusion-write latency on the largest archive to hand and record the number — it
  is fork (c)'s escape hatch.

**Shipped, with four departures from the spec above** (see
[SLICE-LOG](../SLICE-LOG.md) for the reasoning):

1. **The authored entry *set* is enumerated from the index, not bookkept per path.** The
   spec's "deletion and re-slugging must move or drop the entry explicitly" turned out to
   be the bug rather than the fix: a record that is gone contributes no path, so removal,
   trash/restore and re-slug need no code of their own. `rebaseline()` falls out of the
   same design as one line.
2. **The legacy fill-in is one pass, not a trickle.** Fork (f) expected entries to appear
   "as records are touched"; the absent-→-mint rule applied uniformly means the *first*
   mutation on a pre-49 archive hashes every sidecar once. Full coverage immediately
   beats months of partial coverage, and steady state still does no hashing.
3. **`rebaseline()` rebuilds the index first**, so one op means "accept the disk" for
   both derived things rather than leaving the user to remember `reindex` as well.
4. **The schema-spec entry joined the carry-forward rule** instead of being re-hashed
   every commit, closing the same laundering hole for it. A future GeneaLogic shipping a
   revised spec must replace the entry when it replaces the file (in the migration
   pipeline, where such a change lands) or verify will say so — loudly, which is the safe
   direction.

**Fork (c)'s measurement, taken 2026-08-09 — the escape hatch is not needed.** On a copy
of the real archive (21 artifacts, 45 conclusion records) `manifest.json` went 4.7 KB →
16 KB, and the one-time fill-in pass was lost in process-launch noise. Synthetically at
**3,000 conclusion records** the manifest is **516 KB** and a `person add` costs **20.4 ms**
against a **8.9 ms** launch-and-open baseline — so ~11.5 ms for the whole mutation
including rewriting a half-megabyte file. A separate `manifest-metadata.json` stays
unbuilt. **Still owed: the hand-test.**
