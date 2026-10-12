# 45h — `county`/`country` were never match kinds

**45h ✅ — `county`/`country` were never match kinds** (model + format). Shipped as
specced below, forks (a), (b) and (d) unchanged, **fork (c) refined during
implementation** (full writeup in [`SLICE-LOG.md`](../SLICE-LOG.md)).
**Fork (c) assumed a determinate legacy mapping; there isn't one.** It said a stored
`county` decodes to `within` + "the matching granularity" — but `county` was emitted
for **two** claims at two scores (*the town agreed*, 80; *same province*, 55), so
recovering which one a record meant takes a score heuristic that holds only for values
this matcher wrote. This repo's own golden fixture stores `county` at **50**, which
`PlaceMatching` never emitted, and it broke the heuristic on the first run. Settled by
**keeping the word and changing only the field it lives in**: a retired kind decodes to
`within` with the original string preserved in `granularity` as `.unknown("county")`,
and from there round-trips verbatim like any open-vocab value. A stored breakdown is a
*verdict at a time* (45c) — preserved, not re-derived — and an open vocabulary's
`.unknown` is exactly "a value this version has no name for". This also drops the
decode-only asymmetry the spec had proposed, so there is no silent rewrite.
No score moved (pinned to exact integers in `DimensionScorerTests`, which is what makes
"representation-only" provable), `toolIdentifier` unchanged, and the app needed no
change as predicted. 437 → 443 engine tests, 97 → 98 CLI. *Original plan follows.*
**Letter is creation order; scheduled before 45e**, the 45g precedent — 45e is a link-*production*
accelerator, and this is a stored closed vocabulary whose migration cost grows with
every link confirmed. The archive holds 14 links today and **none of them stores a
place dimension at all** (all 14 are `name.exact`), so the change is nearly free right
now and never will be again.
**Problem:** `MatchKind` is closed and holds `exact`/`phonetic`/`known-variant`/
`within`/`none` **and** `county`/`country`. The first five describe *how this matcher
reached a verdict* — GeneaLogic's own domain, correctly closed per spec §7. The last
two describe **the world's administrative geography**, which is not GeneaLogic's domain
and is not exhaustible: Polish gmina/powiat/województwo, Japanese 都道府県/市/区, and
Ottoman vilayet/sanjak/kaza do not map onto county/country. The enum is already
straining — `PlaceMatching` returns `.county` for two different claims (*the town
agreed, the empire above it didn't* at 80, and *same province, different town* at 55).
§7's rule is about **domain, not convenience**, and by it these two cases are simply
misfiled. Surfaced by an extensibility review after 45g.
**Layer:** `GeneaLogicModel` (`MatchKind`, `MatchDimension` + a custom `init(from:)`)
+ `GeneaLogicMatch` (`PlaceMatching` only) + **spec in both copies** + CLI rendering.
**The app needs no change — it names no `MatchKind` case.** This *is* a format change,
which is why it is specced before it is built.
**Design forks.** **(a) Where does place granularity go? → out of `MatchKind`, into a
new optional open `granularity` on `MatchDimension`.** Place agreement that isn't exact
becomes `kind: "within"` — its existing meaning, *inside a tolerance* — carrying the
granularity beside it. The alternative, opening `MatchKind`, would open a vocabulary
that is correctly closed for its other five cases in order to fix two that don't belong
in it. A third option, a bare component count (*1 of 3 matched*), loses **direction**:
town-agreed and country-agreed are both "1 of 3" and mean opposite things.
**(b) What are `granularity`'s initial cases? → structural, not administrative:**
`specific` (the most-specific component agreed, coarser ones differ — the border case,
`Łomża, Russia` vs `Łomża, Poland`), `partial` (agreement from the coarse end inward,
more than one component — same province, different town), `coarse` (only the least-
specific component agreed — both in Poland). Structural because **that is what the
algorithm actually computes**: it counts components and has no gazetteer, so it does not
know what a county *is*, and naming the output administratively was the original error.
Open, so a future gazetteer-backed matcher can emit `parish` or `admin2` without a
format break. The three map 1:1 onto today's 80/55/30, so **no score moves**.
**(c) What about an archive already carrying `county`/`country`? → decode-only
aliases.** A closed vocabulary errors on an unrecognized value, so simply deleting the
cases would make a v1.0-written archive **fail to load** — the exact failure 44h exists
to prevent, and "our corpus has none" is not a format argument. They keep parsing,
mapping to `within` + the matching granularity, and are **never encoded again**; the
next write normalizes them silently, which the spec must state. A schema-version bump
and a migration pass is the heavier alternative and buys nothing for a value no writer
has ever emitted.
**(d) Does `Matcher.toolIdentifier` bump? → no.** Its rule is to bump when a change
makes old breakdowns non-comparable, and its own carve-out is that a refactor which
provably cannot move a score leaves it alone. Every score here is byte-identical; only
the representation changes. Bumping would assert a scoring change that did not happen.
**Out of scope:** a real gazetteer or place authority — the thing that would let
`granularity` mean `admin2` rather than "the third component from the left" — which is
a much larger slice and needs a data source; **reversed hierarchies** (East Asian
addresses are conventionally most-*general*-first, which today's most-specific-first
parse reads inside-out), a parsing question that wants a corpus before it is designed;
and re-scoring stored links.
**Verification:** round-trip tests for a dimension carrying each new `granularity` plus
an `.unknown` that must stay unknown; **a decode test per legacy value** — a link JSON
carrying `"county"`/`"country"` loads, maps to the right kind + granularity, and
re-encodes in the new form; `PlaceMatching`'s existing tests keep their **scores**
(80/55/30) and change only their kind, which is what makes "representation-only"
provable rather than asserted; `SchemaSpecTests` for the two spec copies. Linux-verified.
**Hand-test:** `genea match explain` on a pair whose records both state a birth place,
and confirm the real archive still opens.
