# 45 — the scoring core

**45 ✅ — the scoring core.** Shipped as specced below, with three resolutions the
build forced (full writeup in [`SLICE-LOG.md`](../SLICE-LOG.md)). The D–M table is
faithful — the JewishGen chart's own examples pass verbatim. **`MatchKind` is closed,
so the near-miss band became `.within` with `delta`**: reporting a keyer-missed pair
as `.phonetic` would claim an algorithm that didn't run, and `.none` with a non-zero
score contradicts itself. **The keyer's honest failures are pinned as tests** —
`Fay`/`Faye` key apart (a silent trailing `e` moves `AY` into its before-vowel code)
and are the same person in the real archive, caught only by the edit-distance band;
`Zelig`/`Sidney` correctly doesn't match, since an americanization is not a sound.
**Two defects the tests caught in the scorer:** the exact band compared token arrays
rather than sets, contradicting its own documented rule and demoting surname-first
records to near misses; and the roll-up couldn't separate a bare name match from one
corroborated three ways (a mean over one perfect dimension and over four are both
100), fixed with a corroboration factor over *agreeing* dimensions only. No format,
engine, CLI or app change; 378 macOS / 375 Linux (+83), CLI unchanged.
*Original plan follows.* **Problem:** nothing computes a match; §4.6 is a design, not code.
**Layer:** model-adjacent pure functions, no format change, **no `Archive`
dependency** — input is two plain value structs (a concluded-person view; a mention
view carrying its `RecordedFact`s, role, and co-mentions), output is a
`MatchBreakdown`. Building the inputs from an archive is 45b's job; that seam is
what keeps this target testable without a filesystem and reusable by Phase 4.
Contents: Unicode-aware name normalization (NFC, case-fold, diacritic strip);
the **D–M keyer**; the five dimension scorers (`name`, `birthYear`, `birthPlace`,
`spouseName`, `parents`) per §4.6 — birth-year proximity with century-widening
tolerance, place granularity exact/county/country, the relational dimensions found
through `PersonRole` co-mentions rather than mention-to-mention links; **conflict
detection** (populating `conflicts`, which drops confidence sharply rather than
being averaged away); GPS weights (`sourceAuthorityTier` × `sourceDerivation` →
`sourceAuthorityWeight`; the effective per-fact `InformationQuality` →
`informationQualityWeight`); and the aggregate roll-up. **Sub-decision already
taken:** the name dimension is **keyer + Jaro–Winkler**, not keys alone — D–M is
deliberately coarse and collapses `Hanner`/`Hanaur`/`Honner` to one code, so the
key selects `MatchKind.phonetic` and the edit-distance term grades the score.
(Double Metaphone and Damerau–Levenshtein are a later keyer slice; a schema review
recommends complementing phonetic keys with edit distance per the historical-record
name-resolution literature, which is the reasoning applied here.) **Out of scope:**
candidate generation, any archive I/O, person↔person scoring (45j reuses these
functions). **Verification:** unit tests per scorer plus golden pairs from the real
corpus (`Hanaur`/`Hanner`, `Fay`/`Faye`, `Zelig`/`Sidney` — the last being a
*known-variant* case, not a phonetic one, and expected to score low until a variant
table exists); scores must be deterministic. Linux-verified.
