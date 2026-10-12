# 44c — the `localRef` re-binding bug + the shared-rule consolidation behind it

**44c ✅ — the `localRef` re-binding bug + the shared-rule consolidation behind it** (promoted
out of 44b's /code-review). Both steps shipped. A real data-integrity defect in the shipped app,
and the duplication that caused it.
**The bug.** `AssertionEditorSheet` (the app's Persons Mentioned add path, slice 19) mints a
new `PersonMention.localRef` as the *lowest unused* `p<n>`. Removing a mention deliberately
leaves any `EvidenceLink` pointing at its ref dangling (§2.3, no cascade). So: remove a linked
mention, add another, and the new mention inherits the freed ref — the surviving link now
resolves to it, silently re-binding that citation to a **different person**. A visible dangle
becomes an invisible wrong conclusion, which is the worst direction for this failure to run:
the person's Sources section reads plausibly and is simply wrong. Reachable in a few clicks,
and more likely in the app than in the CLI.
**Why it survived.** Both halves were individually tested — ref reuse, and links surviving a
mention removal — but nothing composed them. 44b hit the same hole in its own new copy of the
rule and fixed it there (the mint now skips refs `links(forArtifact:)` still claims); the app
is still exposed, and the two copies are now *divergent*, which is precisely the problem 44c
exists to end.
**The root cause, and the actual scope.** Four format-level rules now have two or three
independent implementations, each copy carrying a doc comment naming the copy it must stay in
sync with — an accurate description of drift risk, not a mitigation:
`localRef` minting (app vs. CLI), person display-name resolution (engine-private vs. app vs.
CLI), `full`-from-parts synthesis (`PersonDraft.resolvedNames()` vs. CLI), and open-vocab
case-folding (the app's 42c `factType(forEventType:)` vs. the CLI's `OpenVocabulary.parsing`).
The right home for all four is **`GeneaLogicModel`** — one rule, three consumers, and Phase 4's
Vapor target inherits them rather than growing a fourth copy. Same argument for `FactScope`
(a `FactType` knows which store it belongs to; the app enforces that only *implicitly*, by
scoping its pickers, so nothing structurally stops a wrong-store fact there either).
**Sequencing:** fix the app's `localRef` mint first with a regression test that composes the
two halves (so the defect is closed on its own, independently reviewable), then do the
consolidation and delete the copies. Unlike 44b this is **not** engine-free — it's a model
addition plus app edits, so it needs Linux verification per CLAUDE.md, and every moved rule
wants a round-trip test in the model target where it now lives.
**✅ Step 1 shipped.** The rule moved to `PersonMention.nextLocalRef(in:claimedBy:)` in
`GeneaLogicModel` (7 tests, Linux-verified, 251 → 258); both the app and the CLI now call it and
their copies are gone. Verified in the *app* — the site that was exposed — by seeding the exact
scenario with the CLI, adding a mention through the inspector, and checking the **data**: the
mint returned `p2`, and the surviving citation reads as a dangle instead of falsely naming the
new person. The regression test was mutation-checked (reverting the fix fails it).
**A constraint discovered while scoping step 2 — do not fold case in `init(parsing:)`.** The
obvious home for the open-vocabulary case-fold looks like `OpenVocabulary.init(parsing:)`, but
that is the **decode** path: folding there would silently rewrite stored values on re-encode
(`.unknown("birth")` → `.birth`), breaking the format's unknown-preserving round-trip
guarantee — a much worse bug than the duplication it fixes. The fold is *input normalization*
and must stay a **separate** model helper (shipped as `OpenVocabulary.parsingLeniently(_:)`) that the
app and CLI call at their input boundaries, leaving decode verbatim.
**✅ Step 2 shipped.** All four rules now live in `GeneaLogicModel` and every hand-written copy
is deleted: `PersonMention.nextLocalRef(in:claimedBy:)`, `PersonName.resolvedText` /
`hasDerivedFull` / `deriving(type:given:surname:full:)`, `Person.displayName`, and
`OpenVocabulary.parsingLeniently`. The engine (`PersonSummary`, `PersonDraft.resolvedNames`),
the app (`PersonDetailView.displayName`, `FactSuggestion.factType(forEventType:)`) and the CLI
(`ConclusionsFormat`, `OpenVocabulary+CLI`) all forward to them. **Placeholders stay with the
consumer** — "Unnamed person" / "(unnamed)" / an empty column are presentation choices that
legitimately differ, and only the *derivation* is shared. **The copies had already drifted**,
which is the argument for having done this: the app trimmed whitespace and the engine and CLI
didn't, and the engine's `full` synthesis left a leading space when `given` was blank (which
would also have made `hasDerivedFull` fail to recognize its own output). Resolved toward the
stricter reading — whitespace-only is not a name. 272 macOS / 269 Linux tests (+14), 45 CLI
unchanged, app builds; the display-name change spot-checked live against the real archive.
