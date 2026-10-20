# 78 — Split `ArchiveModel.swift` by domain

**Problem.** `ArchiveModel.swift` is 4,063 lines in one type, with sections in the order
slices built them: "People" appears three times, and the undo-plumbing section also
holds tag filters, Continuity Camera and integrity checks. Finding the code for one
domain means reading the whole file. An iOS target, when one comes, can't tell what it
can share. ([#19](https://github.com/GeneaLogic/GeneaLogic/issues/19))

**Layer.** App only. No format change, no engine change, and **no behaviour change**:
the code moves, the `mutate` / write-queue pattern stays exactly as it is, and no new
observable sub-models appear (ROADMAP: not unless the scale slice measures a need).

## What moves where

`GeneaLogicApp/Model/`, one `extension ArchiveModel` per file (the project uses
synchronized folders, so no `.pbxproj` edits):

| File | Holds |
| --- | --- |
| `ArchiveModel.swift` | The class body: **every stored property** (Swift allows none in extensions), grouped by domain under `MARK`s. `load`, `refresh`, `bump`; `mutate`, the write queue, the wait indicator; undo registration across the actor hop; `describe(error)` |
| `+Artifacts` | Browse, sort, filter, tag facets; ingest, attach, replace, detach; file roles, metadata, export; delete and its undo; the importer's result and kept scans |
| `+Trash` | Trashed artifacts and files, restore, delete, empty |
| `+People` | Browse and filter; create, edit, delete, merge, with undo |
| `+Relationships` | Relationships and couple facts (43–43c) |
| `+Evidence` | Links, resolving a mention, mention suggestions (42, 45d) |
| `+Review` | Suggested facts, the worklist, suggested relationships, the duplicates lane (42c, 45e–45m) |
| `+Integrity` | Standing damage, the sweep, repair (56, 57, 59); verify, dangling references, rebuild, rebaseline |
| `+ExternalChanges` | Noticing another writer (51) and a change on its way in (61) |
| `+Window` | **The Mac-shaped part:** menu-command routing (F6), sheet and importer triggers, Continuity Camera's menu, navigation. Triggers only: what happens to the data they bring lives in its domain file |

Nothing in the model imports AppKit or SwiftUI today (`ContinuityScanning` is a protocol
whose AppKit side is in `Support/`), so "separated from macOS-only UI" means *which
files an iOS target would replace*. That is `+Window`, plus the window state in the
class body, grouped under one marked `MARK`.

## Design forks

1. **Access control.** `private` is file-scoped, so code that moves away from what it
   calls stops compiling. **Recommended:** widen exactly what crosses a file boundary,
   and nothing else, to `internal`. That includes `mutate`, `registerUndoStep`,
   `bumpAndRefresh`, the setters of `private(set)` state written by a domain file, and
   the helpers two domains share. A `private` member used in one file stays `private`
   there. The cost: views *could* call `mutate` or assign `persons`. The app is one
   module, so nothing short of a separate module enforces the line. **Alternative:**
   move the model into its own module now (a local package target), with the views
   reaching it through `public`. That is the real boundary, but every member a view
   touches would need `public`. It belongs with the iOS target, not here.
2. **One move commit, then the widening.** **Recommended:** commit the file moves
   first, with the access changes they force, and nothing else. Then any tidy-up
   (duplicate `MARK`s, doc comments that point at old line numbers) goes in its own
   commit. `git blame -C -C` then follows every line back through the move.

## Out of scope

- Splitting `ArtifactDetailView.swift`: slice 79 (#20).
- Observable sub-models (`PeopleModel`, …), and any change to invalidation grain: only
  if the scale slice measures a need.
- A separate model module, and anything iOS: with the iOS target.
- Renaming, re-documenting or "improving" moved code, beyond doc comments that the move
  itself makes wrong.

## Verification

- **The app suite, unchanged and green**, locally and on CI. No test edits should be
  needed. If one is, the move changed something.
- **A mechanical check that it is only a move:** the sorted, non-blank lines of the old
  file equal those of the new files, once access modifiers, `extension ArchiveModel {`
  and its closing brace, and `import` lines are stripped. The script stays in the
  scratchpad, and the slice log records its result.
- No Linux run: the app target doesn't build there, and the engine is untouched.
- **Hand-test (the user):** a smoke pass over the sample archive. Add media, edit a
  person, undo and redo, open Trash, open the review inbox. Nothing should look or
  behave any differently.
