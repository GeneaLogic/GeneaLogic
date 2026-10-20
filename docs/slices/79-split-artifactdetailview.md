# 79 — Split `ArtifactDetailView.swift`

**Problem.** `ArtifactDetailView.swift` is 1,855 lines. Most sections are already `View`
structs, but three things keep it one unit. The document pane and the inspector are
computed `some View` properties on the parent. `PersonMentionRow`'s four sub-sections
(stated relationships, resolution control, stored reasoning, recorded facts) are too. And
every section takes its verbs as closures that the parent rebuilds on each body
evaluation. A computed property shares its parent's invalidation boundary, and a view
whose inputs include a fresh closure never compares equal to its previous value. So today
a change to `capturedMetadata`, a menu command, or a file selection re-runs every
section's body, rows included. ([#20](https://github.com/GeneaLogic/GeneaLogic/issues/20))

**Layer.** App only. No format change, no engine change, no model change, and **no
behaviour change**: the same controls do the same things, open the same sheets, and
register the same undo steps with the same names.

## What goes where

`GeneaLogicApp/Views/ArtifactDetail/` (a synchronized folder, so no `.pbxproj` edits):

| File | Holds |
| --- | --- |
| `ArtifactDetailView.swift` | The coordinator: the loaded state (`detail`, `files`, `transcript`, `links`, suggestions, file selection), the `.task` reload, the sheets, menu-command routing and the inspector toggle. Its body composes the two halves. Also `ArtifactDetailPlaceholder` |
| `ArtifactFileActions.swift` | Pop out, open in the default app, save a copy: the verbs that need `openWindow` or AppKit, shared by the header, the Files rows and the Selected File menu. *(Added while building.)* |
| `ArtifactDocumentPane.swift` | The pane, `DocumentHeader`, `FileSelectorStrip`, `DocumentPreview`, `FileChip` |
| `ArtifactInspector.swift` | The inspector's scroll and section order, and `IdentifiersSection` |
| `EditableArtifactFields.swift` | The fields and `EditRow`. Moved unchanged: it already reads the model itself |
| `EventsPlacesSection.swift` | The section, with its delete-by-index verbs moved in from the parent |
| `PersonsMentionedSection.swift` | The section and `SuggestedRelationshipRow` |
| `PersonMentionRow.swift` | The row, plus `StatedRelationshipsLine`, `MentionResolutionControl`, `StoredReasoning` and `MentionRecordedFacts` as their own types |
| `FilesSection.swift` | The section, `FileRow`, `RoleBadge` (also used by `FileChip`) |
| `TranscriptSection.swift`, `EmbeddedMetadataSection.swift` | One section each, with its row |

The rule for every type: **inputs are the values its body reads**, plus `artifactID` when
it acts. `Pending*` and `ResolveRequest` widen from `private` to `internal` where they
cross a file.

## Design forks

1. **How a section acts.** **Recommended:** a section calls model verbs itself, through
   `@Environment(ArchiveModel.self)` and `artifactID` (unlink, navigate, delete an event or
   mention or fact, record or dismiss a suggestion, file role, scan, replace, detach).
   Holding the model costs nothing: observation tracks only the properties a body reads,
   and calling a method from a button reads none. State that one section alone renders is
   read there too: `capturedMetadata[artifactID]` in `EmbeddedMetadataSection`, and
   `persons` in `PersonsMentionedSection`, which resolves each row's person and passes it
   down as a value. Most of the ~25 pass-through closures disappear. **Alternative:**
   keep the closures, as the house style does today. The split is then cosmetic, because
   no section can skip its body.
2. **How a section opens a coordinator-owned sheet.** These are the add and edit sheets,
   resolve, and the transcript editor. Menu commands open them too, so the state has to
   stay on the coordinator. **Recommended:** fold the five pieces of presentation state
   into one `ArtifactSheet` request (an `Identifiable` wrapper with a fresh id, as the
   `Pending*` types have now, over an enum of the five kinds) behind one `.sheet(item:)`.
   Sections take a `Binding<ArtifactSheet?>`, and a binding to `@State` compares by
   location, so it doesn't defeat diffing the way a closure does. The fact editor's
   `mentionName` is built by the row, which already has the mention. **Alternative:** keep
   the five `@State`s and the four `.sheet` modifiers, and pass up to four bindings down two
   levels.
3. **Commit shape.** **Recommended:** as in 78, commit first the pure move of the existing
   struct types into files, with only the access changes they force, checked mechanically
   (the sorted, non-blank lines match). The reshaping (forks 1–2, computed sections into
   types) then goes in its own commit, so `git blame -C -C` follows the moved code and
   the reshaping diff shows only the change.

Judgment calls, not forks: the coordinator keeps its `onChange` reads of the pending
commands and `mutationVersion`. Once its body only composes, re-running it is cheap, and
the guidance's "move it into a modifier" is for an expensive host. No `Equatable`
conformances or `.equatable()` are added. Plain value inputs are enough.

## Out of scope

- Row identity (`\.offset` lists, index-addressed deletes): **79b**. The index-based
  verbs move into their sections as they are.
- [#3](https://github.com/GeneaLogic/GeneaLogic/issues/3) (replacing a file with another type leaves a stale preview), even though
  `DocumentPreview` is the view it lives in.
- The other large views (`IntegrityReportSheet`, `PersonDetailView`). They are mostly
  `View` types already. Anything left goes to the audit (81+).
- Any measured performance claim. The boundaries are correct by construction. Whether
  they matter at scale is for the scale slice.

## Verification

- **The app suite, unchanged and green**, locally and on CI. No test touches these views.
- **The move commit's mechanical check**, as in 78. The script stays in the scratchpad,
  and the slice log records the result.
- No Linux run: the app target doesn't build there, and the engine is untouched.
- **Hand-test (the user)** on the sample archive. Fork 1 rewires every inspector control,
  so the pass covers each one:
  - Add an event and a place (the Add… menu and Artifact ▸ Add Event/Place), then remove
    one.
  - Add, edit and remove a mention. Resolve one, open Why?, Unlink. Re-resolve a dangling
    one. Click the chip to jump to People.
  - Add, edit and remove a recorded fact. Record one suggested relationship and dismiss
    another.
  - Edit the transcript from the section, and from Artifact ▸ Edit Transcript… with the
    inspector hidden.
  - Select files from the strip and from the list. Use every ⋯ action: pop out, default
    app, save a copy, role, scan, Replace…, and Delete (the row's confirm and the menu's).
  - After Scan for Metadata, Apply a suggestion.
  - Rename the title and undo twice (52's focus fix). Toggle the inspector from the
    toolbar and from the View menu.
  - Every step undoes, with the same action name in Edit ▸ Undo.
