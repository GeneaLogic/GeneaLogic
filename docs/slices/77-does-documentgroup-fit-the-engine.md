# 77 — Does DocumentGroup fit the engine?

**Problem.** An archive window is a `WindowGroup(for: URL.self)`, not a document window
(ARCHITECTURE §7). So the app hand-builds what a Mac document app gets from the
system: Open Recent (`ArchiveBookmarks`), Finder opens (`ArchiveOpenCoordinator`),
sandbox scope across windows (`ArchiveAccessStore`), restoration, the welcome window
dismissing itself, and window tabs, which are switched off because they crash. There is
no title-bar proxy icon, so no Rename or Move To. §7 deferred the fix until the SDK 27
`Document` API was usable: a **read-only `DocumentGroup` viewer** (`ReadableDocument`)
with the engine still the only writer. Xcode 27 is now the toolchain, so the question
can be answered. The answer decides whether workstream 5 raises the app's floor to
macOS 27.

**Layer.** App only, and a **prototype**: no format change, no engine change. The slice
merges a decision, not code.

**What the prototype is.** The smallest change that puts an archive in a document
window: a `DocumentGroup(viewer:makeReadableDocument:)` scene with a custom
`DocumentReader`, hosting the existing `ArchiveContainerView`, with the floor at
macOS 27. Whatever else breaks is left broken unless one of the questions needs it.
Throwaway archives only, never a real one.

**The questions.** Each gets an answer, or "unknown without building X".

1. **Opening.** Can `read(from:progress:)` hand over enough to open the archive through
   the engine, without SwiftUI reading or coordinating every file in the package? A
   coordinated read of the package may make iCloud Drive download all of it, which
   57b exists to prevent.
2. **The engine's own writes.** Must they go through
   `configuration.makeFileCoordinator()`? If so, how, without putting
   `NSFileCoordinator` in the Foundation-only engine? An app-side wrapper around
   `mutate`, or a hook the engine is handed, are the candidates.
3. **Changes from outside.** When the engine, `genea` or a sync delivery changes the
   package, does the document system notice, re-read, or show a "changed by another
   application" prompt? Does that replace slice 51's change-token poll, or fight it?
4. **Rename, Move To, Duplicate.** Which ones does a viewer offer, under which
   `CFBundleTypeRole` (it is `Editor` today)? If an open archive can be moved, does the
   engine survive it? It holds the root URL, the SQLite connection and the `flock`.
5. **New Archive and the welcome window.** Does creating through `NSSavePanel` plus
   the engine still work, and how does the new archive reach the document system?
   Does the welcome window (sample, recents) survive next to the Open panel macOS shows
   at launch?
6. **Undo.** Does registering undo on the document's `UndoManager` mark a read-only
   document as edited, or ask to save on close?
7. **Sandbox scope and restoration.** Does the document system's access make
   `ArchiveAccessStore` and the bookmarks redundant, including for restored windows?
8. **CI.** Does GitHub's `macos-26` image (or a newer one) have Xcode 27 for the app
   job?

**Go means** 1, 3, 5 and 6 come out workable, and 8 has an answer. Questions 2, 4 and 7
decide how big the migration is, not whether it happens. On **go**, slices 80
(floor and CI) and 81 (the migration) are specified from the findings. On **no-go**,
the floor stays at macOS 26, 80 and 81 are dropped, and the window behaviour goes to
the audit to fix by hand.

**Forks:**

- **(a) Where the prototype lives.** **A separate branch, `spike-77`** *(recommended)*,
  pushed for reference and deleted once 81 lands or the answer is no. The slice branch
  carries only documents. The alternatives are to commit and revert on the slice branch,
  which leaves noise in `main`'s history, or to build a standalone toy app, which can't
  answer 1–4, because those are about this engine.
- **(b) Where the findings go.** **A `## Findings` section in this file** *(recommended)*,
  with ARCHITECTURE §7's hosting note rewritten to the decision and a SLICE-LOG
  entry. There's no separate findings document, because only this slice reads it.

**Out of scope.**

- Any of the migration itself, the floor change, and CI (80, 81).
- The `ArchiveModel` and `ArtifactDetailView` splits (78, 79).
- [#9](https://github.com/GeneaLogic/GeneaLogic/issues/9) (82), even if the prototype changes it. Write down what was seen.
- The other SDK 27 adoptions (item-binding dialogs and the like). These are for the audit.

**Verification.** No tests, because nothing is merged that runs. Each question's
answer records how it was checked: a log line, a screenshot, a step. **Hand-test** (the user, on
the prototype build): open the sample from Finder and from the Open panel. Check Open
Recent, a second window as a tab, the title-bar menu, quit and relaunch. Run `genea add`
against the open archive from Terminal. Then judge whether it feels like a Mac document
app, which is the reason for the slice.
