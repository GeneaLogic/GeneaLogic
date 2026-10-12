# 44b — CLI conclusions parity

**44b ✅ — CLI conclusions parity.** Shipped as planned below, with three resolutions the
build forced. **Grammar: nouns for the new surface, flat verbs only where a verb joins two
records** — `person …`/`mention …`/`fact …`/`trash …`, leaving `relate`/`unrelate` and
`link`/`unlink` flat (a bare `add` could no longer say *what* it adds, now that four record
kinds exist). **Two scope gaps the plan didn't see, both found by using the thing:** `link`
was **unusable headlessly** — it resolves a `PersonMention`, and nothing in the CLI could
create one, so `mention add|list|remove` had to land too (with `localRef` **minted**, never
supplied, mirroring the app's slice-19 rule); and `trash` was **unreachable** for the same
reason — nothing headless could delete an artifact or detach a file — so `remove`/`detach`
landed as well. **`person set` became `person name add|set|remove`:** the planned single setter
edited a name *in place*, which quietly made a married or alias name unrecordable — a person
could only ever have the name they were created with. A **test caught this**, not review.
**One fact command for both stores** (`fact add --person|--relationship`), routed by target
like the app's unified `FactEditorSheet`, since `PersonFact` is the shape of both; known fact
types are scoped to the store that fits them (`personCases`/`coupleCases`/`parentChildCases`)
while unknown ones still round-trip. Open-vocabulary options now parse **case-insensitively**
— `--type birth` folding to `.birth` rather than minting an `.unknown("birth")` twin that
renders identically but never compares equal, the exact drift the 42c follow-up fixed app-side.
Removals **report what they left dangling** (§2.3, no cascade): a CLI has no undo stack, so
the consequence is stated when it happens rather than left for `verify`. **No engine change**
(the whole slice sits over the slice-40 API; the engine suite stays at 251); 45 CLI tests
(37 as first written, 8 added by review), macOS + **Linux** green — the Linux run being the point, since these tests are the second, app-assumption-free
consumer that de-risks Phase 4. README rewritten around the evidence/conclusions split, and
its end-to-end example verified to run verbatim.

**44b (original plan) — CLI conclusions parity.** The `genea` CLI (Phase 1b) exposes only the
Phase-1 artifact/evidence surface — `create`/`add`/`attach`/`set-meta`/`find`/`list`/
`reindex`/`verify`; it has **zero** conclusions commands, so everything Phase 3 built
(persons, relationships, links, facts, trash) is reachable only from the engine + the
Mac app. Add the conclusions read/write surface over the (final) engine API:
`person add|list|show|set|remove`, `relate`/`unrelate` (+ couple facts), `link`/`unlink`
(resolve a mention), `fact add`, and the trash ops the CLI also lacks. **Why after 44,
not dribbled into each slice:** the conclusions surface is still growing through 43b/44
and the 45+ matcher (merge, suggested-links), so building one consolidated,
coherently-grammared CLI slice over a *settled* surface beats rewriting it against a
moving target. **Payoffs beyond symmetry:** (1) one-line **test-fixture seeding** (a
scripted archive with people + relationships, instead of clicking through the GUI —
the friction this session's live-test hit), and (2) a **second, Linux-capable consumer**
of the conclusions API that catches app-shaped assumptions and **de-risks Phase 4
(Vapor)**, which reuses the kit on Linux. Confined to `GeneaLogicCLI/`, over the final
lookup/mutation API — additive and low-risk. (If fixture-seeding friction bites sooner,
a tiny *seed-only* carve-out — `person add`/`relate`/`link`, write primitives only — can
land earlier as a test aid, deferring the query/display polish to this slice.)
