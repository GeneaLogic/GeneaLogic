# 45e — the app triage inbox

**45e ✅ — the app triage inbox.** Shipped as specced below, all four forks as settled,
with **two hand-test corrections and one spec line dropped as unnecessary** (full writeup
in [`SLICE-LOG.md`](../SLICE-LOG.md)). **The below-threshold mitigation's floor is 1, not 0:**
everyone who resembles a name in no way at all ties at zero, so a zero floor filled the
"closest existing people" list with whoever the uid tiebreak put first — three strangers
presented as candidates, in the one step that exists to prevent a false suggestion. And
the resolve-sheet accessory's per-row breakdown **expander was removed**: it made a
cramped row carry two competing controls to show an accounting the Review pane already
draws properly, so the row keeps its one-line reasoning and the five rows stay one
section away. **The specced local list-patching was dropped**: its purpose was to stop the
queue reshuffling mid-pass, but document order is deterministic and a verdict on one pair
moves nothing else — so the worklist recomputes at `refresh()`'s existing chokepoint
(gated on the section having been opened), which also makes ⌘Z restore a decided row for
free where forward-only patching would have left undo showing a stale queue.
**The gotcha:** the accessory loaded in `.onAppear` on a body that rendered nothing until
candidates arrived — an empty `Group` is `EmptyView`, a view never in the hierarchy never
appears, so it sat empty while the matcher had a 91 to offer, looking exactly like
"nothing matched". The host owns the load now. Also: the app enables
`MemberImportVisibility`, under which 45b's `public import` makes `ScoredMatch` nameable
but not its members readable, so four view files name `GeneaLogicMatch` explicitly (no new
target dependency — the CLI never hit this because it doesn't enable the feature).
**`/code-review` found four defects, all fixed in the slice** (writeup in the log): sections
keyed by artifact *title* rather than `uid` (duplicate `ForEach` ids silently drop rows
from the one list that must not lose a mention); the somebody-new sheet claiming nobody
resembles a name when the resembling person had merely been **rejected** — a false claim
in the step that exists to prevent a duplicate; rejection counting made worklist
construction O(artifacts × links) main-actor decodes on every mutation, to answer a
question only candidate-less rows ask; and `recordReview`'s catch omitting the
`bumpAndRefresh()` its two sibling write paths do deliberately.
**Hand-testing also pulled two things in from *out of scope*** (below) and found three
narrow-container layout bugs from drawing a wide pane's breakdown rows in a 250pt
inspector — `Phonetic` hyphenating, a keyer's name breaking mid-word, the source weights
splitting mid-label — plus a prominent Create button that looked like the default action
without being one, so Return did nothing.
443 → 449 engine tests, macOS and Linux; 98 CLI unchanged; no model, format or spec
change. Hand-tested against a copy of the real archive: 22 unresolved names queued,
confirm/reject/somebody-new and their undos, the written links verified on disk both ways,
45d's rejected-only case, the displacement report driven by a concurrent CLI writer, and
the two duplicate-title and rejected-then-create cases the review turned up.
*Original plan follows.*
**Problem:** suggestions are headless-only. `genea
match` scores, confirms, rejects and explains, but nothing in the app shows a
suggestion — so the matcher accelerates nothing for the person actually cataloguing.
**Layer:** app, **plus one additive engine entry point** (fork (b)). No model, no
format, no schema-spec change; ARCHITECTURE §6.3's example block gains a line.
**Four forks settled 2026-07-29, before any code:**
- **(a) Where does it live? → a fourth toolbar section, not a sheet.**
  `ArchiveTab.review` reuses the shared `NavigationSplitView` (a case in
  `sidebar`/`detail`, so the column width persists across Artifacts/People/Review as
  it does today) and gets per-window `@SceneStorage` selection. Triage is a workspace
  returned to, not a one-shot report — `TrashSheet`/`IntegrityReportSheet` are the
  sheet precedents and both *are* reports; a modal one would also block reading the
  artifact while deciding, which is the act itself.
- **(b) Archive-wide needs an engine call → add
  `suggestLinks(minimumConfidence:limit:) -> [MentionSuggestions]`**, the third
  direction beside per-person and per-artifact. `MatchCorpus.suggestions(persons:artifacts:)`
  already takes both arrays, so this is one corpus build over `index.allArtifacts()`.
  **Grouped, not flat**, and returning *every* unresolved mention — the zero-candidate
  ones are the worklist's whole point (45c). This deliberately widens the slice past
  "app only": the alternative, looping `suggestLinks(forArtifact:)` over
  `model.artifacts`, rebuilds the entire conclusions corpus once per artifact — fine
  at 20 artifacts and wrong as a shape. Ordering stays **document order** (artifact,
  then that artifact's own `personsMentioned` order, per `groupedSuggestions`);
  grouping and sorting for display is the app's business, matching `SuggestedLink`'s
  no-display-fields rule.
- **(c) The cross-person suggested-*facts* lane splits out → 45i.** This entry had
  45e absorbing 44i's deferral because both are the same surface, and they are — but
  the links half is already a full slice (section, worklist, breakdown rendering,
  three write paths with undo, the below-threshold mitigation), and the facts half
  needs its own aggregation pass plus `PersonDetailView`'s `isAlreadyRecorded` dedupe
  hoisted out of the view. Two log entries, two slices (§*How a slice is specified*).
- **(d) The in-place path comes too.** `ResolveMentionSheet` gains a
  ranked-suggestions accessory (`PersonPickerSheet`'s existing `accessory:` slot) fed
  by `suggestLinks(forArtifact:)` filtered to the mention being resolved — the §6.3
  inspector-primary direction, and the spot a cataloguer is actually standing in.
  **A suggestion row resolves through `confirm`, the plain search list through
  `link()`**: the record must say which one the human used, since `link()`'s honest
  minimum is a claim that nothing was computed (45c).
**The breakdown is the UI, not the percentage** (§4.6). The detail pane renders one
row per dimension with kind, score and gloss, keeping the CLI formatter's four
honesty rules verbatim: `nil` → *not assessed* (never `0` — these documents are
silent about most things, and *not assessed* is not *assessed and failed*); a
relational `.none` → *not scored* (45g's positive-only rule); `granularity` rendered
verbatim, so a value this build has no name for still reaches the reader; `conflicts`
as a warning block rather than an averaged-away term. `aggregateConfidence` orders the
queue and never appears alone. Lives in `Support/MatchBreakdown+Display.swift` (the
app's `…+Display` convention), so the two registers can be diffed against each other.
**The writes** are `confirmSuggestion`/`rejectSuggestion` on `ArchiveModel`, both
passing **the score the user was shown** (the engine's `confirm(_ SuggestedLink)`
overload) and both undoable on `resolveMention`'s registration pattern — unlink the
new link, restore every `decision.superseded`, LIFO. Undo of a rejection *is*
`unlink`, which is precisely un-rejecting (45c). The `ReviewDecision`'s displaced link
and any citation the displacement stranded go to `showInfo`, the app-side analog of
45d's displacement report — swallowing them is what 45d fixed in the CLI.
**Somebody new** is `createPersonAndLink(from:in:replacing:)`, which already exists
and is already one undoable step — but **never one click from an empty candidate
list.** An empty list is where the matcher is *least* trustworthy (the
`Zelig`/`Sidney` variant blind spot it cannot see until a variant table exists), so
the action opens a confirm step that first shows what a zero floor turns up —
`suggestLinks(forArtifact:minimumConfidence: 0)` filtered to this mention, no new API
— as "closest existing: Sidney Feldberg — 31, name didn't match", and only then offers
Create. Nothing even at zero is stated plainly rather than read as proof.
**The worklist is recomputed, never stored** (the mini-phase's ephemeral rule):
computed on entering the section and by an explicit Refresh; a decision updates the
list **locally** (drop the resolved mention, drop the rejected candidate) rather than
rescanning, so the pane doesn't reshuffle under the user mid-triage. Scoring stays
synchronous on the main actor — 22 mentions × 11 persons on the real archive, and
`Archive` is main-actor-pinned in the app anyway; off-main scoring and a progress
affordance are a later slice's problem if an archive ever makes them visible. No
confidence-floor control: `Archive.defaultMinimumConfidence` governs the worklist and
the create-new step is the one zero-floor surface.
**Out of scope:** the suggested-facts lane (**45i**); merge (**45f**), which is what
cleans up the duplicates create-new can mint and is why it stays next;
~~**un-rejecting beyond ⌘Z**~~ — *pulled in during hand-testing: the queue said a
candidate "was rejected earlier and isn't offered again" and then offered no way back. ⌘Z
covers the mistake made this session, not one made last week, and the queue is where that
is discovered. `Restore <person>` per tombstone, routed through `unlink` (45c's "no fourth
verb"), no engine change*; batch or auto-confirm above a threshold
(§4.6: the matcher suggests and never commits); a floor control; off-main scoring.
Also pulled in: **a stored breakdown is readable in the app**, via a *Why?* disclosure on
the resolved-mention chip — the pane promises that confirming stores exactly these numbers,
and until then only `genea match explain` could show that it had.
**Verification:** engine tests for the new entry point — every unresolved mention
appears including the zero-candidate ones, resolved mentions don't, rejected pairs
don't, `limit` is per mention, ordering deterministic — macOS **and Linux**. The app
has no test target, so the rest is a **hand-test against a copy of the real archive**
(never the original): confirm, and check the written link carries the matcher's real
dimension scores rather than `100`; reject, refresh, and confirm the pair is gone; ⌘Z
on each of confirm / reject / somebody-new; somebody-new from a no-candidate mention
with the zero-floor list shown; the resolve-sheet accessory; and the case 45d's tuning
pass turned up — a mention whose only candidate was **rejected** must read as
rejected, not as "lower the floor".
