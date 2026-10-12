# 45f — `mergePersons`

**45f ✅ — `mergePersons`.** Shipped as specced below, all four forks as settled, with **one
sub-decision the build sharpened** and no surprises otherwise (full writeup in
[`SLICE-LOG.md`](../SLICE-LOG.md)). The spec said duplicate confirmations collapse and their
citations follow; implementing it made the *converse* explicit — **every other dropped record
reports its strands rather than being repaired**, because a dropped tombstone is a different
claim from the confirmation that displaced it and repointing there would turn a recorded "no"
into evidence. Relationship identity needed the same care: **`couple` compares unordered,
everything else ordered**, since §4.5's couple endpoints are symmetric and parent-child reversed
is a different claim — an open-vocabulary type this build has never heard of gets the
conservative reading. One small shared refactor: `decision(writing:superseding:)`'s
stranded-citation sweep became `strandedCitations(naming:index:)`, now used by both the review
lifecycle and the cascade. **Self-review caught one real defect:** both cleanups ran over every
candidate record, so a merge would silently delete a duplicate edge or stray verdict the survivor
*already had* — an operation may resolve the collisions it creates and may not adopt the ones it
finds. **`/code-review` caught that the fix had reached only the relationship half**, and that the
test covering the link half was **vacuous** (`link()` supersedes the pair itself, so the anomaly
it claimed to build never existed on disk); the rule is now stated once for both halves — the
losing *side* of the cross-person collision goes — and every surviving link naming the absorbed
person is repointed rather than only the winning verdict. **The hand-test caught two more.** A `PersonFact` is a *claim* plus
its *evidence*, and exact-equality union merged them as one thing: two records each carrying the
same birth from their own source became two identical-looking rows, because 42c stamps every
recorded fact with the link it came from — so the citations always differ where the claim agrees.
`unionFacts` now folds on the claim and unions the citations (one fact, two sources), matching
what `planRelationships` already did for a collapsed edge; `1881` vs `1881~` still stay two facts.
And **the collapse tie-break "keep the older record, by lowest uid" was never a tie-break**: this
archive's `UUIDv7` is deliberately non-monotonic within a millisecond, so two records minted in
one pass sorted by their random bits and which of the user's records survived was a coin flip
(the tests passed on luck). The **survivor's own** record is kept now — stable, and what the user
asked for by naming which person to keep. No format change, no schema-spec change, as predicted;
ARCHITECTURE §4.3 gained the *Merging duplicates* paragraph and §6.3 the API lines. 449 → 472
engine tests, 98 → 101 CLI, macOS and Linux. Hand-tested in the app against a throwaway archive: the report
names what moved and what was dropped, ⌘Z restores the pre-merge archive exactly, ⌘⇧Z re-merges,
and `genea verify` is clean after. *Original plan follows.* **Problem:** two records describe one
person — 45e's *somebody new* mints them by design, and a hand-catalogued archive
accumulates them anyway — and nothing can combine them; the manual loop got by on
reject-and-relink, which throws away one side's evidence rather than joining it.
**Layer:** engine mutation + CLI + app. **No format change and no schema-spec change**
— `PersonID` is referenced from exactly two record kinds (`EvidenceLink.personUid`,
`Relationship.person1Uid`/`person2Uid`), so merge is pure record rewriting and no
persisted field changes; ARCHITECTURE §4.3 gains a *Merging duplicates* paragraph and
§6.3 the API line, and the two byte-identical schema copies are untouched.
**The cascade is the slice, and it is §2.3's exception.** Every removal so far
deliberately leaves dangles (`removePerson` says so in its own doc comment; 44g's
`ReplacePersonSheet` exists to repair them). Merge is the one operation that *must*
rewrite other records, because the absorbed person is not gone — they were never a
second person. That inverts the undo shape too: the usual snapshot ping-pong can't
reverse an N-record rewrite, so the engine returns a **`MergeDecision`** carrying the
before-state of everything it touched (the survivor snapshot, the uid-faithful absorbed
`Person`, before-snapshots of every relinked link and rewritten relationship, the
dropped records, and any stranded citations) and owns the reverse in `revertMerge(_:)`
— `ReviewDecision`'s precedent (45c), one step up in blast radius.
**Four forks settled 2026-07-30, before any code:**
- **(a) Detection splits out → 45j.** This entry paired duplicate *detection* with the
  merge mutation. Detection needs a person↔person scorer that does not exist —
  `Matcher.score` is mention→person, and `ScoredMatch`'s two GPS weights are
  meaningless between two *conclusions* — so it carries its own roll-up question and
  its own surface. Merge alone is already engine cascade + decision value + revert +
  CLI + app. Two log entries, two slices (§*How a slice is specified*). Merge is
  reached by **naming the other person** (`PersonPickerSheet`, which exists); the
  duplicates 45e can mint are found by the user who just made them, so nothing waits
  on detection.
- **(b) Contradicting verdicts on the same mention → the confirmation wins.** After the
  rewrite the survivor can hold a confirmation (from A) *and* a rejection tombstone
  (from B) on the same `(artifact, localRef, person)` triple, which 45c forbids. The
  tombstone said *this mention is not B*; the merge asserts *B is A*, and it is the
  later and more specific human judgement, so the tombstone is dropped — into
  `MergeDecision`, so undo restores it and both front ends report it the way 45d's
  displacement report does. Not silently: a dropped "no" is exactly the kind of loss
  that has to be visible.
- **(c) Relationship collisions → drop self-loops, collapse identical edges, report
  both.** An A↔B relationship becomes a person married to themselves; identical edges
  (same type, same endpoints) appear twice. Both are removed, both are in the decision,
  and **facts on a collapsed duplicate are union'd into the kept edge** rather than
  discarded — the alternative leaves the Tree and Relatives surfaces drawing doubled
  relatives and a self-partner, which the projection would have to render.
- **(d) `genea person merge` ships in the same slice.** The mini-phase's CLI-before-app
  rule (45d → 45e) and 44b/44d's headless-parity promise, but the real reason is that
  this is the most destructive engine operation yet and its failure mode is data loss:
  it wants a scriptable path, hand-testable **on Linux**, against a copy of the real
  archive before a GUI touches it.
**Sub-decisions taken while specifying** (so they aren't discovered mid-build):
**the rewrite includes rejection tombstones** (`links(for:includeRejected: true)`) —
45c's rule is *does this surface mean citation or record on disk*, and this one means
records on disk; a tombstone left naming the absorbed uid dangles.
**Duplicate confirmations on the same triple collapse, keeping the lower uid, and any
`supportedByLinks` citation of the dropped one is repointed to the kept one** — the two
links assert the identical thing, so repointing preserves meaning where stranding would
destroy it; every *other* dropped record reports its strands rather than being quietly
repaired. **Names and facts union** survivor-first, dropping exact duplicates
(`PersonName`/`PersonFact` are `Equatable`); contradictory facts are kept and left
visible, because that is the honest state and the user prunes it. `identifierURI` takes
the survivor's, else the absorbed's; **the survivor keeps its own `uid` and
`provenance`** — same concluded identity, and a "merged from …" audit field would be a
format change. Guards: both persons must exist, and merging a person into themselves
throws. **The app's confirm step names the two people, not a preview of counts** — a
preview would need a plan/apply split in the engine for a question the result already
answers; the exact report goes to `showInfo` after, beside undo.
**Out of scope:** duplicate detection (**45j**); a forwarding/"sameAs" tombstone for the
absorbed uid (a format change, and nothing outside the archive references a `PersonID`
until Phase 4 publishing); a field-level merge picker; a `--dry-run` preview; merging
*artifacts*; cross-archive merge.
**Verification:** engine tests — links relinked including tombstones, relationships
rewritten, a self-loop dropped, a duplicate edge collapsed with its facts union'd, the
verdict clash resolved the (b) way, names/facts union'd without duplicates,
**`findDanglingReferences()` clean after a merge**, and `revertMerge` restoring every
touched record equal to its before-state (the round-trip that makes the cascade
reversible). CLI tests on macOS **and Linux**. **Hand-test** against a copy of the real
archive: mint a duplicate through 45e's *somebody new*, merge it away from the app,
check the Sources / Relatives / Tree / Review surfaces all show one person, then ⌘Z and
confirm the archive is back — and the same merge through `genea person merge`.
