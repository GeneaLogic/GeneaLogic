# 45+ — the matcher mini-phase (`GeneaLogicMatch`)

**Goal:** the app suggests evidence→person links with visible decomposed reasoning,
and the user confirms/rejects/merges from a queue (ARCHITECTURE §4.6).

**Builds on 44h/44i's frozen format.** Every field the confidence framework reads —
mention-scoped `RecordedFact`s (§10.6 resolved toward (b)), `sourceDerivation`, name
`language`/`script`, open `PersonRole`, integer scores — landed there, so **the matcher
itself needed no schema change**: 45–45j are format-neutral, and 45c changes what an
*existing field* means, which is spec work rather than a format change. Two later slices
do change it, and neither is the matcher: **45k** states relationships *between mentions*
(a gap 45g exposed) and **45m** stores a declined suggestion (a gap 45j's fork exposed).
Both are additive and both were specced before their build.

**Four forks settled 2026-07-25, before any code:**

- **Suggestions are ephemeral.** `suggestLinks` returns transient values; nothing is
  written until a human confirms (a link) or rejects (a tombstone link). This keeps
  `conclusions/` meaning *conclusions* (§2.3), spares every read path from filtering
  unreviewed machine guesses, and makes a re-run reflect current data rather than
  reconcile against stale suggestion records. **Consequence to document in 45c:**
  `LinkReviewStatus.machineSuggested` becomes legal on disk but **never written by
  GeneaLogic**, and §4.4's example JSON — which shows a persisted suggestion — must
  say so.
- **Daitch–Mokotoff Soundex is the first keyer, not Double Metaphone.** ARCHITECTURE
  §4.6 names Double Metaphone throughout, but that is English phonetics and this
  corpus is Ashkenazi/Slavic: the real archive holds names like `Szlama Feldberg` (the fictional stand-in since 74), and
  Polish `sz`/`cz`/`rz` is exactly what D–M was built for. D–M is ~100
  documented public-domain rules emitting multiple codes per name. `nameAlgo` records
  which keyer ran, so adding Double Metaphone later needs no format change.
- **CLI before the app**, inverting the 44b/44d order. Scoring needs iteration
  against real data, and a shell loop over the real archive is a far faster tuning
  loop than clicking a GUI — and the Linux consumer stays honest before UI
  assumptions harden.
- **A confirmed suggestion stores the computed breakdown**, not today's honest
  minimum — `reviewStatus: .humanConfirmed` with the matcher's real dimension scores
  and `provenance.createdBy: .machine`. Storing decomposed reasoning is the entire
  point of §4.6; discarding it at the moment of confirmation would make a confirmed
  suggestion indistinguishable from a hand-made link. `link()`'s own doc comment
  already anticipates this revisit.

*The ladder, [45](45-the-scoring-core.md) through [45p](45p-the-quadratic-duplicate-pass-made-cheap.md), is one file per slice.*

**Explicitly out of the whole mini-phase:** an index projection for candidate
blocking (→ **45p**); a user-editable name-variant table (the `Zelig`/`Sidney` case —
worth a later slice, and `MatchKind.knownVariant` already exists for it); a **real
gazetteer** (parked candidate, below); and any learning from confirm/reject history.

**Parked candidate — a gazetteer-backed place matcher.** *Named here because two shipped
documents already promise it and nothing schedules it:* `MatchGranularity` is open
specifically "so that a gazetteer-backed implementation can state a real level (`parish`,
`admin2`) without a format change" (spec §, ARCHITECTURE §4.6), and `PlaceMatching`'s
every design note turns on **not having one**. An unscheduled promise in two places is
the kind of assumption that should be written down as a candidate rather than left
implicit.
**What it would actually buy**, beyond the depth question **45o** solves more cheaply:
the *border problem* resolved as fact rather than heuristic (`Łomża, Russia` and `Łomża,
Poland` are one town under two empires — today a string rule reaches that answer, and a
gazetteer would *know* it); place-name **variants and exonyms**, which for this corpus is
the same size of problem as personal-name variants — `Lemberg`/`Lwów`/`Lviv`,
`Wilno`/`Vilnius` are one place per record set and score as unrelated strings today; and
genuine administrative levels for `granularity`.
**Why it is parked and not scheduled — the fork is *where the data comes from*, and the
engine's contract makes it sharp.** `GeneaLogicKit` is Foundation-only, Linux-buildable
and **does no networking**, so a gazetteer is either (a) **bundled**, which means dataset
size and licensing in the package — GeoNames is CC BY, which is workable but is a
distribution decision, not a coding one; (b) **injected**, the `MetadataExtractor` seam's
shape (§6.4): the core defines a `PlaceResolver` protocol and holds no data, and a host
supplies one, which keeps the contract intact and makes the feature optional; or (c) a
**user-curated place table** in the archive itself, the place-side sibling of the parked
name-variant table, which needs no external data and is a format change.
(b) looks right on the architecture and (c) is the one a researcher can act on today, but
this needs settling deliberately rather than in passing. **Not before Phase 4**: it is an
accuracy upgrade to a matcher that works, and 45o takes the concrete pain out of it.

**Exit criteria (manual loop):** from a curated archive, the user creates persons,
links artifact mentions to them, asserts relationships, and a tree renders from the
conclusions — reproducible after an index rebuild. **Exit criteria (matcher
mini-phase):** the app suggests links with visible decomposed reasoning, and the
user confirms/rejects/merges from that queue.
