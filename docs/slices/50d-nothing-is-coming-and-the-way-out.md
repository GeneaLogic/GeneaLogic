# 50d — nothing is coming, and the way out ✅

**Problem.** After 50 and 50b one state survives: `manifest.files` names a path whose
expected version never arrives, and **no evidence decides it**. `verifyIntegrity()`
reports `awaiting-delivery` for that path on every run for ever,
`manifestDeliveryLooksComplete` stays false, the witness never settles, the index is
never reconciled, 61's indicator escalates and is telling the literal truth, and the
record is **frozen against further edits** — while the engine's own advice forbids
`rebaseline`, the one operation that would clear it. Three ways in, none distinguishable
from the others or from a slow link: a provider that ate one machine's edit outright, a
sender that went away mid-delivery, and an `.index/` recreated so 50's superseded rows
are gone and the merge degraded to taking the arriving manifest whole. The only evidence
is **time without progress** — 61's stall heuristic, a hedge rather than a diagnosis. So
the way out has to be a human's, and this slice is about making theirs a safe one.

**The third cause turned out not to reach this verb, and the tests are what said so.**
A recreated `.index/` has no witness at all, which 60b fork (b) deliberately routes to
*damage* rather than to an arrival — so the archive reports a checksum mismatch and tells
the user to verify, never to wait. That state was therefore never one this verb is the way
out of; it is `rebaseline`'s, behind its own archive-wide warning, and the verb refuses it.
Pinned by `aRecreatedIndexReportsDamageAndIsRefused` so the claim is not carried forward as
though it had been built. Two causes remain, and they are the two shapes fork (a) splits on.

**The missing detection cannot be bought off the shelf, and that is now measured.** The
macOS 26 sync controls do not supply it: pause fails `featureUnsupported` on the shipping
OS, and `fetchLatestRemoteVersionOfItem` is *package*-granular, so it cannot answer "is
**this path** still coming" — see § *macOS 26 file-provider sync controls* above.

**Layer.** Engine (`GeneaLogicArchive`) for the operation, CLI for the verb, app for the
affordance. **No format change:** the operation writes the same `manifest.files` entries
the engine already writes, and the note in fork (c) lives in `.index/` beside 50b's
`deleted_path` — machine-local, outside the manifest/index/integrity passes.

**Design forks** (recommendations; to settle with the user before any code):

- **(a) What the verb does when the file *is* present — recommend re-mint from disk.**
  The manifest names hash `H_remote`; disk holds `H_local`. Withdrawing the expectation
  means making the entry describe what is actually here: re-mint hash, `byteLength` and
  timestamp from the file. *Dropping the entry instead* was considered and is worse — it
  removes a real file from the manifest's coverage, re-opening exactly the blindness 49
  closed. Where the file is **absent**, there is nothing to describe and the entry is
  dropped, which is 50b's shape arrived at by a human instead of by evidence. Re-minting
  from disk is the laundering 49 fork (a) forbids *without* a human; this verb is that
  human, scoped to one named path, which is the whole reason it is safe where
  `rebaseline` is not.
- **(b) Must the path actually be awaited — recommend yes, refuse otherwise.** Accept
  only a path currently reported `awaiting-delivery`. Cheap, and it stops the verb
  becoming a general "rewrite my manifest" tool. **Not** a stall *threshold*: gating on
  elapsed time would dress the hedge up as a diagnosis, and 61 already owns the
  heuristic. 61's escalation is the **prompt** for this verb, never its gate.
- **(c) Record the abandonment — recommend yes, minimally.** An `abandoned_path` row
  beside 50b's `deleted_path`, surfaced once by verify as a note rather than an issue.
  50b's lesson was that an override must be *recorded*, not inferred later from a state
  that looks ordinary; without the row, a human's decision is indistinguishable from a
  normal write, and a version that lands afterwards changes the record under the user
  with no trail saying why.
- **(d) Scope — recommend one path per invocation, repeatable; no `--all`.** A sweep flag
  is `rebaseline` with a friendlier name, and it re-mints archive-wide from disk, which is
  precisely what 49 gated behind a human per decision.
- **(e) The app affordance — recommend a per-row action on the Verify panel's
  awaiting-delivery rows**, with 61's escalated bar pointing there. The panel is where
  the paths are already named, and this must be path-scoped; an action on the bar itself
  was considered and declined, because the bar names no path. **Wording is part of the
  fork:** it says *Stop waiting for this file*, never *Repair* or *Fix* — nothing here is
  damaged, and 57's rule applies (a sentence that implies assurance it did not earn is
  worse than no sentence).

**Out of scope** (each with its owner):

- **Diagnosing *why* nothing is coming.** No detection exists, and the measurement above
  says the platform does not sell one. The verb acts on the user's judgement, not on a
  finding.
- **Automatic or timed abandonment.** A slow link is structurally indistinguishable from
  a stopped one — 61's own rule, and the reason this is a verb and not a sweep.
- **Propagating the abandonment to the other machine.** Its manifest still names the
  path and its next mutation re-asserts it. Same reach limit 50b recorded for deletions:
  what crosses machines is the sync provider's ground, not the engine's.
- **Merging two versions of one record** → Phase 4+. **Conflicted-copy *files*** →
  [50c](50c-a-conflicted-copy-must-not-become-the-record.md) ✅.

**How it will be verified.** Engine tests for each of the three ways in, driven through
the `scripts/deliver.sh` shapes; **recoverability** as the load-bearing one — abandon `P`,
then let the real version land, and the next rebuild walks it in while the next mutation
re-mints it, with verify clean throughout (this property is what makes the verb offerable
where `rebaseline` is not); **refusal** in each of fork (b)'s three shapes — a path the manifest
does not name, one whose file already matches, and (the one the gate exists for) a
disagreement no delivery covers, which is damage; **convergence** — a second abandonment of
the same path has nothing to do and says so; and a **negative test that the re-mint is
reachable only through this verb**, never from an ordinary mutation, so 49 fork (a)'s rule
keeps holding by construction. Linux parity via
`scripts/linux-test.sh`, CLI tests for the verb and its refusals. **Hand-test:**
`deliver.sh` gains an `abandon` step for the engine half; the app half is the user's — the
escalated bar, the named row, the action, and the archive settling afterwards.

**Built as specced, all five forks as recommended**, with three things the build
established that the spec had not:

- **Two engine bugs the tests found, both in the commit path.** `commitManifest` compares
  the recomputed list against **the list the body left behind**, so an abandonment whose
  file never arrived — the one mutation whose entire effect is a removal that adds nothing
  back — recomputed to exactly that list and **skipped the write**: the removal lived in
  memory until the next `reloadManifest()` threw it away, and the archive stayed wedged.
  And an abandoned entry was being recorded as one *we superseded*, which is the opposite
  of true — we never had that version, we gave up on it — so 50's merge would have read a
  genuine later delivery of it as a stale manifest and **discarded the very version the
  user stopped waiting for**. That second one is the difference between *recoverable* and
  *lost*, and recoverability is the whole licence for offering this verb where `rebaseline`
  is refused.
- **The note is self-describing, because clearing it from the mutation path is not
  enough.** An arrival is adopted through `commitManifest`'s delivered-manifest branch,
  which recomputes nothing and so has no before-and-after to compare — the note survived
  the very event that made it false. `abandoned_path` therefore stores the checksum the
  abandonment left standing (the empty string where the entry was dropped), and any reader
  decides it against the manifest in front of them. Additive, no `schemaVersion` bump, and
  preserved across a rebuild for the reason `deleted_path` is.
- **A wording bug the rig caught and the tests could not.** The note read *"the manifest
  records this machine's copy"* — false for the absent case, where there is no copy and the
  entry was dropped. Now generic across both shapes in CLI and app, which is the honest
  register anyway: the note explains the *decision*, and the manifest already says which
  shape it was.

**`/code-review` found the gate was asking a narrower question than
`verifyIntegrity()`, twice, and the notes were only half-cleared.** Three engine findings,
each now a test:

- **A payload path was a silent no-op.** `payloadEntries` re-derives every attached file's
  entry from the `record.json` that claims it, so dropping the entry achieved nothing — and
  the call still wrote its note, leaving `verify` reporting one path as **both awaited and
  abandoned, for ever**, and accepting the request again every time. It is now refused, with
  the same scope rule `rebaseline()` has and for the same reason: the manifest does not
  author that checksum. The remedy for a payload that is never coming is to take the claim
  out of the record (`detachFile`), which is a different and more destructive verb.
- **`.interruptedWrite` outranks `.awaitingDelivery` in verify, and the gate did not
  know it.** With the sentinel set, verify said *interrupted write* and the verb accepted
  the path anyway — blessing what may be half a commit of ours as the version of record and
  routing around `rebaseline()`'s warning. Now refused ahead of the coverage test, in
  verify's own order.
- **Stale notes were filtered but never deleted, so one could resurrect.** A dropped-entry
  note records the empty string; it stops standing when the version lands and the entry
  reappears — and stands **again, permanently**, the moment anything removes that entry
  later, such as the user deleting the record. `forgetAbandoned` was dead code with a doc
  comment claiming otherwise. Pruning now runs on **both** of `commitManifest`'s paths,
  including the delivered-manifest branch, because an arrival is what most often falsifies
  a note and that branch recomputes nothing.

**And writing the interrupted-write guard deadlocked instantly**: `interruptedWriteSuspected`
takes `lock`, and `withState`'s body is already inside it. Now has a `…Locked` sibling, the
same shape as `deliveryCoverageLocked()`. Two app findings went with them — the confirmation
read `abandoning` inside its own action while the dismissal setter nils it (now the
`presenting:` overload), and `abandon(_:)` had been inserted under `rebaseline()`'s doc
comment, leaving each headed by the other's description.

**Verified.** 15 `AbandonDeliveryTests` and 3 `AbandonDeliveryCommandTests`; **836 engine
tests on macOS, 833 on Linux**, 149 CLI on both, app suite green. Three app tests pin the
half a view test cannot: a note is not a finding, so the report stays `isClean` — which is
exactly what would make the note vanish on the clean branch of the panel if nobody looked
for it.

**Hand-tested (engine half)** on `scripts/deliver.sh`, which grew an `abandon` step
reachable by doing *less* — run `manifest`, never run `record`, which is a sender that went
away mid-delivery. Stepped `setup → manifest → status → abandon`: the wedge before, clean
after, the note standing. Then the recoverability claim end to end, which is the one worth
having watched: `record` delivered the straggler after the abandonment, `reindex` walked it
in, the person appeared, and the next mutation minted its entry — 5 tracked → 7, verify
clean, note gone.

**Hand-tested (app half), driven on screen 2026-08-30.** Seven checks against a staged
`setup → manifest` (and never `record`): 61's bar prompts the verb; the *Still Arriving*
row names the path and keeps its wait advice; the action sits on the row while the footer
offers **no** Accept Current Contents, since an arrival is not rebaselinable; Cancel is
inert; **Stop Waiting fires** — the `presenting:` fix, which until then had been reasoned
rather than reproduced, and which the dialog proves by interpolating the path into its own
body; the report goes clean with *Stopped Waiting* in the row's place and the bar gone; and
the note survives a re-verify. `genea verify` on the same archive agrees with the panel.
**Not covered:** a refusal reaching the sheet-local alert, which needs the row to resolve
between the sweep and the click.
