# 45p — the quadratic duplicate pass, made cheap

**45p ✅ — the quadratic duplicate pass, made cheap** (engine). Also from 45j's review.
`duplicateCandidates()` is `n(n−1)/2` scored pairs under `Archive`'s lock; the roadmap
accepted quadratic for this phase and put blocking out of the mini-phase, and both still
hold — what does not is a **UI** calling it synchronously, which 45m's lane would.
Contents: an off-main entry point and a progress affordance, plus the candidate-blocking
pre-filter this mini-phase deferred, **behind the same API** so that if the filter is a
true superset it changes no results (45b's standing condition for blocking). Ordered
before 45m if the lane proves to need it. **Reduced by 45m, which shipped the off-main
half itself** (`duplicateScanInput()` under the lock + a pure `duplicateCandidates(in:)`,
with a progress row): what remains here is the **pre-filter** — the work that makes the
sweep cheap rather than merely off the main actor.

**Shipped, but not as the pre-filter this specced — that turned out to be unsound for
this scorer, and the slice's goal was met a safer way.** Two independent reasons a
candidate gate cannot be built here: a key gate makes the name dimension's `.within`
band unreachable (`Fay`/`Faye` are one woman and key apart — the ground on which 45b
already rejected blocking for suggestions), and, decisively,
`defaultMinimumDuplicateConfidence` is *calibrated* on a pair whose names agree on
**nothing** and which is corroborated three ways. A name-keyed gate drops exactly the
pair the floor exists to admit, and the failure mode is an invisible false negative in
the one surface whose job is to not miss a duplicate.
**So the cost came out of the comparison instead of the candidate set.** Profiling the
release build put ~60µs of a ~92µs pair in Daitch–Mokotoff keying — a pure function of a
string, recomputed once per comparison a token appeared in. Memoizing it makes keying
`O(distinct name tokens)` rather than `O(pairs)`: **~92µs → ~15µs per pair, 6× measured**,
and, being the same function on the same input, it provably changes no result. 45b's
standing condition ("if it is a superset it changes no results") is satisfied by not
filtering at all. 1,000 persons goes 46s → 7s; 5,000 is ~3min and still quadratic.
**What is left is the real floor:** Jaro–Winkler over token pairs, inherently pairwise.
Going below it needs a gate bounding *string similarity* rather than phonetic equality —
an ngram index, its own slice, and still owing the superset proof. **Parked with data**
rather than specced, since nothing in the archives this phase targets needs it.
