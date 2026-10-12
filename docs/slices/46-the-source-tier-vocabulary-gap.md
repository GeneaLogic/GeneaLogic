# 46 ✅ — the source-tier vocabulary gap

**Shipped as specced below**, all four forks as settled: `government` (80) and
`monument` (60), `.unknown` still carrying whatever fits neither bucket,
`Matcher.toolIdentifier` → `genealogic-matcher/6`, and no retagging of the real
archive inside the slice. Two deviations, both small. The claim that CLI `--help`
picks the cases up "from `knownCases` for free" was **wrong** — the `--source-tier`
help string is hand-written, so it was edited by hand. And the open-vocabulary test's
sample unknown, `"probate"`, is a **court** record, which `government` now covers: a
sample chosen as "a plausible genre we haven't got yet" is a test scheduled to fail,
so it moved to `"shipManifest"` — the value this slice decided *stays* unknown.
The gap's real shape got pinned as a test while doing it: **a tier a cataloguer would
reach for as a fallback must score above saying nothing**, which `compiled` (25, against
an untiered 40) does not — tagging honestly scored a document *below* leaving it blank.

**`/code-review` found one regression, fixed in the slice, and one gap it opened → 46b.**
The regression: promotion is not behaviour-neutral for **search**. A pre-46 archive stores
`"Government"` as `.unknown`, a query for it now folds to `.government`, and `find
--source-tier Government` stopped matching — so "no migration needed" was true of storage
and false of lookup. `OpenVocabulary.denotesSameTerm(as:)` folds both sides at the one
comparison site; an unpromoted term with identical casing matched throughout, which is the
control that pins the promotion rather than the casing as the cause.

**Problem:** `SourceAuthorityTier` has no bucket for civil records that aren't vital
registration — draft registrations, naturalization, immigration manifests, military,
court, land — which is the largest genre in an American-immigrant corpus; and none for
a gravestone or monument. So they land on `compiled`, which is **not a neutral
default**: it scores 25/100, the lowest tier, and asserts *"somebody's conclusion, not
evidence"* (`ConfidenceWeights.tierBase`). In the real archive **12 of 20 artifacts are
tagged `compiled`**, including a draft registration, a naturalization certificate, an
arrival manifest and a memorial photograph — all originals, held as images. Surfaced by
45d's tuning pass.

**Layer:** model + the `GeneaLogicMatch` weight table + **spec in both copies** + CLI
help + the app's picker. **Format-adjacent, not a format break:** the vocabulary is
open, so an archive already carrying `"government"` as `.unknown` starts decoding it as
a known case and re-encodes the identical string. No schema bump and no migration —
stored `EvidenceLink` breakdowns keep their scores by design (45c: a confirmation is a
verdict at a time), so only a re-run scores differently.

**It is a records-honesty slice, not a recall slice — measured, not assumed.**
Retagging 45d's weakest true positive moved it 74 → 77, and even the `vital` ceiling
reaches only 86, because the roll-up bounds the source discount to `0.6...1.0` on
purpose (a good source cannot invent an agreement that isn't there). Justify it on
cataloguing grounds; if it is ever argued for on *scoring* grounds, that is the signal
it has been mis-scoped.

**Design forks:**

- **How many tiers? → two: `government` and `monument`,** letting `.unknown` carry
  whatever fits neither. GPS's real axes are already modeled
  (`sourceDerivation`, per-fact `informationQuality`); the tier is a genre convenience.
  A draft card's weakness is not its genre but that its birth year is the registrant's
  *recollection* — which `informationQuality: .secondary` on that one `RecordedFact`
  already says, and says better. Keeping the tier coarse is what stops the two axes
  from re-encoding each other. The counter-argument (manifests have a distinctly worse
  quality profile) is a fact-level claim and belongs on the fact.
  ***Clarified after the hand-test*, which is where this fork's wording was found to be
  doing damage.** It listed immigration and military among the genres left to `.unknown`,
  while the Problem statement above counts them in the gap — so the archive's arrival
  manifest stayed on `compiled` through a retagging pass that moved everything else.
  Both readings can't be right, and the tier's own definition settles it: **`government`
  is read by who created the record, not by the errand it served.** A passenger list is a
  filing retained by the receiving authority; service records are an authority's too. What
  actually stays `.unknown` is what fits *no* bucket — institutional registers, commercial
  records, photographs. This widens the reading of a bucket, not the list of buckets, so
  no code, weight or vocabulary changed; it is now stated in **both spec copies**, since
  a distinction only a fork records is one the next cataloguer re-derives or gets wrong.
- **The weights? → `government` 80, `monument` 60.** A government record is an
  authority's contemporaneous record of the subject's own statement: a notch under
  `vital` (90), because it registers an application rather than the event it reports. A
  stone is contemporaneous with the death and family-erected — strong for death, weak
  for birth — so between `census` (65) and `bible` (55).
- **Bump `Matcher.toolIdentifier`? → yes.** Its rule is to bump whenever a change makes
  old breakdowns non-comparable with new ones, and re-weighting a tier does exactly
  that. Cheap here; the alternative is a stored breakdown whose tool string is a lie.
- **Retag the real archive within the slice? → no.** That is the user's data and a
  manual pass. The slice ships the vocabulary; the cataloguing is a hand-test of it.

**Out of scope:** any change to the roll-up's `0.6...1.0` source band (a scoring
decision, and 45d's numbers give no reason to touch it); a `sourceDerivation` backfill
across the archive (cataloguing again — though note it is currently unset on *every*
artifact, costing a flat 10%); re-scoring existing links.

**Verification:** round-trip tests for both new cases plus an `.unknown` that must stay
unknown; a weight-table test per new tier; `SchemaSpecTests` for the two spec copies;
CLI `--help` picks them up from `knownCases` for free *(wrong — the `--source-tier` help
string is hand-written; edited by hand)*. Linux-verified. **Hand-test:**
the app's source-tier picker offers the new cases, and an archive tagged with them
still opens in the *previous* build — the open-vocabulary promise, and the one thing a
test in this repo cannot prove.
