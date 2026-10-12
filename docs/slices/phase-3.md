# Phase 3 — Conclusions, matching & the derived tree ✅ DONE (slices 40–46b merged)

**Goal:** turn evidence into a reviewable tree.

## Approach (settled 2026-07 — the shape before slicing)

Three decisions frame the build:

- **Manual-first, matcher later.** The automatic matcher (`GeneaLogicMatch`) is
  the heaviest piece and only *suggests* links a human then confirms — it's
  layered *on top of* the manual loop, not underneath it. So Phase 3 builds the
  **manual conclusions loop end-to-end first** (create a person → resolve a
  mention to that person → assert relationships → render the derived tree), and
  the matcher + suggested-links queue land afterward as their own mini-phase.
  Building manual-first also yields real conclusions data to validate the matcher
  against.
- **Tab-bar UI — three peer worlds in each archive window.** `ArchiveContainerView`
  becomes a window-level `TabView` (`.tabViewStyle(.sidebarAdaptable)`, macOS 15+;
  unrelated to the slice-35 `allowsAutomaticWindowTabbing = false`, which killed
  *NSWindow* tabs): **Artifacts** (today's split view, unchanged), **People** (the
  new person surface), **Tree** (the derived read-only view, empty until
  conclusions exist). The one per-window `ArchiveModel` is shared across tabs;
  per-tab selection stays separate (`@SceneStorage` keyed per tab so tab +
  selection both restore). Chrome is tab-scoped — the toolbar `+`, `.searchable`,
  the `ListControlsBar`, and the artifact-specific menu commands belong to the
  Artifacts tab; People gets its own add/search; Tree is navigation-only.
- **Resolution is inspector-primary.** A researcher turns a `PersonMention` into a
  concluded person mainly from the **artifact inspector's Persons Mentioned
  section** ("Link to person…", existing or new) — where the mention actually is —
  with the People view as a secondary entry.

## What already exists (engine)

- **Write path** — `addPerson` / `addRelationship` / `link(mention, to:)`, all with
  honest provenance and covered by `ConclusionsTests` (incl. `link`'s honest
  manual-confirmation shape — no forged machine scores; ARCHITECTURE §4.4).
- **Person read path** — `persons()`, `person(withID:)`, `persons(matching:)`
  (name/place/fact-type/date-range), and the conclusions-aware
  `artifacts(mentioning: PersonID)`.
- Drafts (`PersonDraft`, `RelationshipDraft`), the vocab enums (`RelationshipType`,
  `FactType`, `NameType`), and `MentionRef`.

## Engine gaps Phase 3 must fill (each Linux-verified)

- **Public read accessors** for `relationships(of: PersonID)` and
  `links(for: PersonID)` / `links(forArtifact:)` — the index has
  `allRelationships()`/`allLinks()` internally but they aren't exposed, and the
  person-detail + tree views need them.
- **Review-lifecycle mutations** — none exist yet: `unlink`/`removeLink` (reject a
  link), `removePerson`, `removeRelationship`, `updatePerson` (edit concluded
  names/facts).
- The **derived tree** starts app-side over `persons()` + a new `relationships()`
  accessor; a dedicated index projection is a later optimization, not a slice-1
  need.

## Slice ladder (manual-first)

Each rung is its own file: [40](40-engine.md) through [44h](44h-matcher-precursor-format-revision.md); the matcher that follows is [its own phase file](phase-3-matcher.md).
