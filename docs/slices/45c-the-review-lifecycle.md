# 45c — the review lifecycle

**45c ✅ — the review lifecycle.** Shipped as specced below, with four forks settled with
the user before any code (full writeup in [`SLICE-LOG.md`](../SLICE-LOG.md)). `confirm`/`reject`
store the matcher's **real** dimension scores — a confirmation is a verdict on the pair, not a
re-scoring of the evidence, so a weak match a human accepts keeps saying it was weak; `link()`'s
honest minimum stays right for a mention resolved unaided, and its flagged-for-review note is
resolved rather than deleted. **A pair holds one verdict** — `link`/`confirm`/`reject` each
replace any existing link for the triple, reporting it (and any citation the removal stranded)
in a `ReviewDecision` so undo can repair it. This **reverses the fork as first settled**, which allowed same-status duplicates:
that is safe for confirmations and unsafe for rejections, since each tombstone forecloses the
pair independently and `unlink` is uid-addressed — laying a silent trap under 45d's `unreject`.
Un-rejecting is `unlink` — a tombstone *is* an `EvidenceLink`, so no fourth verb. Rejections are
hidden by **default** (`includeRejected: true` opts in), but **two surfaces deliberately keep
seeing them**: `findDanglingReferences()`, because a tombstone naming a deleted artifact dangles
like anything else, and — **the one real bug the audit found** — `PersonMention.nextLocalRef`,
which must not reissue a ref a tombstone claims, or a recorded "this is not Szlama" silently
re-aims at whoever next holds `p3`. *The rule is not "hide rejections" but "does this surface mean
**citation** or **record on disk**".* The artifact direction became **grouped per mention**
(`[MentionSuggestions]`, replacing 45b's flat return, `limit` now per mention): a mention nothing
matched used to vanish, making "no mentions", "all resolved" and "a name never seen before" one
empty result — and the third is the somebody-new case 45e needs. Spec §6.3 + ARCHITECTURE §4.4
updated in both copies (§4.4's example showed the persisted `machine-suggested` record we don't
write); no field added, no schema bump. 426 macOS / 423 Linux (+27), 70 CLI unchanged; app and CLI
touched only where the audit required. *Original plan follows.* **Problem:** confirming a
suggestion has no honest write path, and rejecting one has no memory, so the
matcher would re-suggest a rejected pair forever. **Layer:** engine + **spec in
both copies**; no new fields, but `reviewStatus` becomes load-bearing where it was
previously always `.humanConfirmed`. Adds a confirm entry point carrying the
computed breakdown (beside, not replacing, manual `link()`), and **rejection
tombstones** — an `EvidenceLink` with `.humanRejected` and the computed breakdown,
which is precisely the three-state lifecycle §4.4 already documents. **The audit is
the slice:** every existing consumer must now exclude rejected links —
`links(for:)`, `links(forArtifact:)`, `artifacts(mentioning:)`, the 44e dangling
sweep, `TreeProjection` inputs, the app's Sources section and resolved-mention chip,
CLI `person show`/`verify`. A missed one silently resurrects a rejection as a
citation. **Also add the unresolved-mention shape 45b left out** (found while
building it): `suggestLinks` returns *scored pairs*, so a mention whose candidates
all fall below threshold simply doesn't appear — and nothing can then distinguish
"no mentions", "all mentions resolved", and "an unresolved mention that matched
nothing". The third is exactly the *this is a new person* case, and it is currently
invisible. Either an `unresolvedMentions(in:)` query or a per-mention grouping for
the artifact direction in which a mention may carry zero candidates; prefer the
latter, since the artifact direction is the triage surface 45e draws. **Out of
scope:** the queue UI; un-rejecting from the app (the CLI gets it first).
**Verification:** a test per consumer proving a rejected link is invisible to it;
a mention with no candidates is still reported as unresolved; round-trip on the
tombstone; Linux-verified.
