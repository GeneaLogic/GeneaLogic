# 45b — candidate generation + `suggestLinks`

**45b ✅ — candidate generation + `suggestLinks`.** Shipped as specced below with
one deliberate reversal: **the phonetic-key pre-filter was dropped for brute force.**
A key gate makes 45's `.within` band unreachable from an archive — `Fay`/`Faye` key
apart and are the same woman in the real corpus — and a gate wide enough to preserve
it must stay a superset of everything the scorer can score, an invariant with no
compiler check whose failure mode is an invisible false negative. Neither entry point
is quadratic (one person × every mention, or one artifact's mentions × every person),
so blocking bought nothing; it stays available later as a strict optimization behind
the same API. **`suggestLinks` is a method on `Archive`, not `Matcher.suggestLinks(for:in:)`
as §6.3 sketched** — the dependency runs Archive → Match → Model so the scoring core
stays archive-free; §6.3 updated. Adds `matchScore(of:against:)` (no threshold, no
skip rules) so 45d's `match explain` can stay engine-free as specced. Skip rules:
a `.humanConfirmed` link resolves a mention for *everyone*, a `.humanRejected`
tombstone forecloses that pair only, and `.machineSuggested` on disk is ignored as
the unreviewed guess it is. No format change; 399 macOS / 396 Linux (+21), CLI and
app untouched. Validated against a copy of the real archive: of the 14 links the user
had made by hand, the matcher recovers **14/14 with the correct person ranked first**,
and the one pair it offers above the floor that the user hadn't linked is correct. *Original plan follows.* **Problem:** the scorer
has no way to be pointed at an archive. **Layer:** `GeneaLogicArchive` (or a thin
`Matcher` facade per §6.3), no format change. Projects archive records into 45's
inputs, pre-filters candidates by phonetic key, and returns a **transient**
`SuggestedLink` (the pair + breakdown + weights, no uid — it is not a record).
Both directions, since resolution is inspector-primary: `suggestLinks(for:
PersonID, in:)` per §6.3's sketch **and** `suggestLinks(forArtifact:)`. Skips
mentions already linked and pairs already rejected (45c's tombstones). Brute force
over `persons()` is correct at this scale. **Out of scope:** a SQLite projection
for blocking (an optimization with no current need); persisting anything.
**Verification:** engine tests over seeded archives — a suggestion is found, an
already-linked mention is not re-suggested, ordering is stable. Linux-verified.
