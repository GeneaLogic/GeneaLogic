# 42 — resolve a mention → person

**42 — resolve a mention → person** ✅ from the inspector's Persons Mentioned
section — the evidence→conclusion bridge. Each mention row shows a **Resolve…**
affordance (unresolved) or a tappable **chip** (→ concluded person, jumps to the
People tab) + **Unlink** (resolved). The `ResolveMentionSheet` links an existing
person (searchable, via the engine's `persons(matching:)`) or **creates a new one**
seeded from the recorded name and links in one grouped-undo step. Over the slice-40
`EvidenceLink` API (`link`/`unlink`→`restoreLink`, `links(forArtifact:)`); all
undoable, in-session only; no cascade (§2.3 — a dangling link reads "Unknown person").
/code-review (finder agents) fixed one real bug (an orphaned un-undoable person if the
link write failed after `addPerson`) + three cleanups (shared `RowRemoveButton`,
shared `PersonSummary.browseSubtitle`, engine-backed picker search). No engine change
(193/190 + 6 CLI unchanged); every flow live-verified.
