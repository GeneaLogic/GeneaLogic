# 46b ✅ — `sourceAuthorityTier` asserts a tier nobody chose (off 46's review)

**Shipped as specced below**, with the three forks settled by the user before any code:
**(a) the optional field**, not an `unstated` known case — "no answer" must not be
re-encoded as an answer, and `.unknown` already means something else; **(b) nothing
migrated** — a stored `compiled` may be deliberate, and a sweep cannot tell the two apart;
**(c) the app surfaces the debt** rather than asking during import — a per-file prompt
would put a dialog on the path the user takes most.
The **format change** is `sourceAuthorityTier` → optional, `decodeIfPresent`/
`encodeIfPresent`, spec updated in both copies. No schema bump: an archive written before
today carries the key and keeps it. The three entry points that were doing the asserting
all stop — `genea add` loses its `compiled` default, `set-meta` gains
`--clear-source-tier` (a settable field must be clearable or *unstated* is a one-way
door), and the app's `ingest(_:)` writes no tier at all. `ArtifactSummary.sourceAuthorityTier`
and `ArtifactDraft`'s went optional with it; the SQLite index never stored the tier, so it
needed no version bump.
**The sidebar surfaces the count**, as a banner that also filters to exactly those
artifacts — and **releases the filter when the count reaches zero**, since tagging the
last one hides the banner and with it the only control that turns the filter off.
An uncatalogued artifact **matches no tier query**: letting absence match anything would
make `--source-tier vital` widen as the archive grows less complete.

**Problem:** 46 shipped the vocabulary and left the thing that actually *assigns* it. Two
entry points stamp `compiled` on documents the user has never characterised — `genea add`
defaults `--source-tier` to it, and the app's `ingest(_:)` sets `.compiled` unconditionally
on every imported file. So the **12-of-20 `compiled` population 46 cites as its motivation is
generated, not mis-tagged by hand**, and it regenerates on the next import; retagging by hand
fixes the archive until the next drag-in. Both defaults fail the test 46 just added — the
score lands at 25 × 0.9 ≈ 23, below the 40 an uncharacterised record scores — and both assert
*"somebody's conclusion, not evidence"* about a document held as an original image.

**Why it is a slice and not a fix inside 46:** there is no honest default available.
`Artifact.sourceAuthorityTier` is **non-optional**, so every entry point must name a genre,
and every known case is a claim. The fix is to make it **optional**, so it follows the rule
its own sibling already documents — *absent means unstated, never a default good value*
(`Artifact.sourceDerivation`, slice 44h) — which is a **format change** and needs the call
before it is built. The weight table already handles it: `tierBase` takes an optional and
scores `nil` as 40, so nothing in the matcher changes.

**Design forks to settle first:** (a) optional field vs. an `unstated` known case — the
latter is cheaper but re-encodes "no answer" as an answer, and `.unknown` already means
"a genre this build hasn't heard of", which is a different thing; (b) whether existing
`compiled` artifacts are migrated (they cannot be distinguished from deliberate ones —
argues for leaving them and letting the hand-pass do it); (c) whether the app's import
sheet should *ask*, which is the only way a default stops being a guess.

**Out of scope:** the vocabulary itself (46, shipped); retagging the real archive.
