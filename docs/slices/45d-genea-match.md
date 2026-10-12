# 45d — `genea match`

**45d ✅ — `genea match`** (CLI). Shipped as specced below — CLI-only apart from **one
engine fix review turned up in 45c's committed code** (see below); no model, spec or
app change (full writeup in [`SLICE-LOG.md`](../SLICE-LOG.md)).
**Both suggestion directions print the same six columns**, of which 1–3 are exactly the
triple the other four verbs take, so a suggestion pipes into a decision unreshaped;
the engine's two *shapes* (flat vs. grouped) stay an engine concern. A mention
nothing matched is a row with `-` placeholders rather than an absence — 45c's
grouping would be pointless otherwise, and mid-row empty columns collapse under a
shell `read`. **The one thing the hand-run changed:** that row first blamed the
confidence floor unconditionally, though a candidate is dropped for two reasons and
the engine's result can't tell them apart — so a user who had rejected the only
candidate would lower `--min-confidence` forever while the fix was one `unreject`;
it now counts the mention's rejections and says so. `unreject` clears **every**
tombstone on the pair (honoring its promise against an archive another writer left
duplicates in) and **refuses a confirmation**, naming `genea unlink` instead — both
are `EvidenceLink`s and the CLI has no undo. Confirms 45b's `public import` bet: the
CLI names `ScoredMatch` without depending on `GeneaLogicMatch`. **Tuning pass** (a
copy of the real archive with its links stripped, re-derived through the CLI):
**14/14 recovered, all ranked first, all above the default floor** — lowest true
positive 74 against a highest runner-up of 30, so 50 sits in a 44-point gap. It also
made 45b's data question concrete: **no artifact sets `sourceDerivation` at all**, and
`compiled` is a catch-all for twelve records that are originals, costing them ~50
points of source weight — a cataloguing fix, not a matcher one, and invisible until
now because the name dimension carries recall alone; now specced as **slice 46**.
**`/code-review` found a data-loss ordering bug in 45c's shipped code**, fixed here
rather than deferred: `link`/`confirm`/`reject` deleted the pair's existing verdict
*before* writing its replacement, and `withState` has no rollback — so a failed write
destroyed the old verdict and threw, meaning no `ReviewDecision` came back and neither
the CLI's displacement report nor the app's undo could name what was lost. Now
write-then-supersede: the failure window holds two links instead of none, which is
visible and repairable where the loss was neither. 70 → 96 CLI tests, macOS and Linux;
426 engine tests unchanged. *Original plan follows.*
**Problem:** the matcher is unreachable and
untunable without a GUI. **Layer:** pure `GeneaLogicCLI/`, no engine change.
`match suggest` (per-person or per-artifact, threshold flag), `match explain`
(the decomposed breakdown for one pair — the text form of what the app will draw),
`match confirm`, `match reject`, `match unreject`. Noun-grammar consistent with
44b's `person …`/`mention …`. **Out of scope:** batch auto-confirm above a
threshold — the matcher suggests and never commits (§4.6). **Verification:** a CLI
test suite on macOS **and Linux**; then the real tuning pass against the actual
archive, which is what this slice exists for.
