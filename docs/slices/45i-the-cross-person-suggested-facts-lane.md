# 45i — the cross-person suggested-facts lane

**45i ✅ — the cross-person suggested-facts lane.** Shipped as specced below, all three forks
as settled and no surprises in the build (writeup in [`SLICE-LOG.md`](../SLICE-LOG.md)). The
hoist is the slice: `SuggestedFacts` now holds the one answer to *what is a suggestion* and
*when is it already recorded*, including the couple-facts half of the dedupe, and both
surfaces call it. `Archive.links(includeRejected:)` landed with 45c's audit test — a third
citation surface gets the same scrutiny as the first two. 474 macOS / 471 Linux (+2), CLI
and format untouched. *Original plan follows.* **Problem:** a suggested fact
is only visible on whichever person happens to be selected, so promoting recorded
evidence means walking the People list one at a time. Deferred from 44i; split out of
45e by its fork (c). **Letter is creation order; scheduled after 45f** — merge closes
the duplicate-cleanup gap 45e opens, and this is an accelerator with nothing waiting
on it. **Layer:** app, **plus one additive read-only engine accessor** (fork (c)); no
format and no spec change. `FactSuggestion`, the editor prefill, `FactSuggestionRow`
and the one-click Record path all already exist, so the slice is mostly assembly —
a second lane over every person's linked evidence, grouped by person, with the same
Record / Edit… / Apply… actions.
**The dedupe rule is the work:** `loadLinkedEvidence` and `isAlreadyRecorded` are
private `PersonDetailView` code, and a cross-person pass needs both hoisted somewhere
shared **without changing what they decide** — a lane that disagreed with the person
pane about the same person would be worse than no lane. Hoisted **whole** (sources and
suggestions in one return, the lane ignoring the sources half) into
`Support/SuggestedFacts.swift` as pure functions over already-loaded inputs —
links, the cited artifacts' records, and the person's `facts` **plus their couple
`Relationship.facts`**, which is the half of the dedupe easiest to drop and the one
that silently re-offers an already-promoted marriage. `ArchiveModel` supplies the two
call sites (one person; the whole archive) and keeps no view logic.

**Three forks settled 2026-07-30, before any code:**
- **(a) One combined sidebar, not a lane picker.** The Review list gains a
  **"Suggested Facts"** section under the existing per-artifact groups of unresolved
  names — no mode to switch, nothing hidden behind a segment. The two granularities
  stay legible because they land in *different sections*: names are mention rows under
  an artifact title, facts are **one row per person** (fork (b)). The count strip
  reports both figures rather than picking one.
- **(b) A facts row is a person, not a suggestion.** The pane shows all of that
  person's suggestion rows at once, each with its existing inline actions, so acting on
  eight facts for one person is one selection — and it puts the lane's pane and
  `PersonDetailView`'s own Suggested Facts section side by side, which is exactly the
  agreement the slice has to prove. **Consequence:** the two lanes now share one
  selection space, so `ReviewItem.ID` becomes a **discriminated** string
  (`mention|ART-…|p3` vs `person|PER-…`) behind a small `ReviewSelection` round-trip.
  One `@SceneStorage` value still carries it; a stale unprefixed id from a previous
  launch simply fails to resolve and falls back to the placeholder.
- **(c) Add `Archive.links(includeRejected:)` — the slice widens past "app only".**
  `links(for:)` decodes **every link in the archive** per call (`index.allLinks()`), so
  a per-person loop is O(persons × all-links) main-actor JSON decodes on every
  mutation — the shape 45e's fork (b) already rejected once, for the same reason, and
  the reason it added an archive-wide `suggestLinks`. The fix is ~5 lines beside its two
  siblings in `Archive+Lookup`, and it **must inherit their default-hiding rule**: this
  is the *citation* reading of links (45c), so rejections are excluded unless asked for.
  Artifact records are cached across the whole sweep, and `relationships()` is fetched
  once rather than per person.

**Out of scope:** link triage (45e); any change to what a suggestion *is* or how it is
scored; an off-main sweep or progress affordance (same call as 45e — a different slice).
**Verification:** engine tests for the new accessor (returns every link, hides
rejections by default, surfaces them on request, stable order), **Linux-verified**.
The lane itself has no test target — **hand-test:** a fact recorded from the lane leaves
the lane and returns on ⌘Z; the lane and `PersonDetailView`'s own section agree, item for
item, for the same person — *including* a person whose marriage was already promoted onto
the couple relationship; and the names lane's rows, order and selection are unchanged.
