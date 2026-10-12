# 42b — person "Sources" section

**42b ✅ — person "Sources" section** (the symmetric other half of the bridge):
from a `Person`, show which artifacts cite it and jump back to the artifact —
the reverse of slice 42's chip-tap. Read-only over `links(for: PersonID)` (slice
40): a **Sources** section in `PersonDetailView` listing the citing artifact +
the mention's name-as-recorded, tapping to select that artifact on the Artifacts
tab (`navigateToArtifact` → the one-shot `pendingArtifactNavigation` intent, the
mirror of `pendingPersonNavigation`), plus an **Unlink** (the shared, undoable
`unlinkMention`). A dangling link (deleted artifact) shows "Unknown artifact" with
the jump disabled but Unlink still live (§2.3, no cascade). New app surface:
`ArchiveModel.personLinks(for:)` (mirror of `artifactLinks(for:)`) +
`navigateToArtifact`; the section loads off `mutationVersion` so an unlink (here or
on the artifact side) refreshes it. No engine change (the read accessor exists);
/code-review clean, every flow live-verified (display, cross-tab jump, unlink,
⌘Z restore).
