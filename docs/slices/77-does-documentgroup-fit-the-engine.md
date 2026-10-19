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

**Why read-only, not read-write.** A writable `Document` saves by asking the document for
a snapshot of its in-memory state and handing it to a `DocumentWriter`, whose one method
writes to a `destination` URL. Apple's guide says that destination is not the document's
`fileURL`, and the SDK has no option to write in place. The system then swaps the new
package in for the old. So the engine can only take part by building the package anew at
each save, inside the writer. That would undo two guarantees (question 0 checked both,
and corrected two weaker reasons first given here):

- **An edit is on disk the moment it is made**, which slices 65 and 69 and
  `kill-test.sh` test. An autosave comes about 15 seconds after a change, so on-save
  writing loses whatever came after the last one.
- **`genea` and agents write alongside the window**, under the `flock` (47, 51). Any
  outside write between a change and its autosave stops the save behind a modal
  "changed by another application" alert. For an archive designed to be written from
  Terminal while it is open, that alert would be routine.

Two reasons first given here were wrong or unproven. The swap does not copy the media:
the staging package is hard-linked from the original. And the open index may well survive
a swap that keeps its file's inode, though that was not tested.

GeneaLogic's archive is the files on disk, written by more than one writer. It is more
like a library than a document. Read-write would add Save, Revert, Versions and the
edited dot, and none of them mean much for an archive that is always saved. Everything
wanted from `DocumentGroup` comes with the viewer.

**What the prototype is.** The smallest change that puts an archive in a document
window: a `DocumentGroup(viewer:makeReadableDocument:)` scene with a custom
`DocumentReader`, hosting the existing `ArchiveContainerView`, with the floor at
macOS 27. Whatever else breaks is left broken unless one of the questions needs it.
Throwaway archives only, never a real one.

**The questions.** Each gets an answer, or "unknown without building X".

0. **The premise.** Check this first, with a throwaway writable `Document` on a scratch
   package. On one save, log `destination` against `configuration.fileURL`, and see how
   the result replaces the original. If the destination *is* the file URL, or the
   replacement is per file, read-write comes back as an option. Then put the question
   to the user before going on.
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

## Findings

**0. The premise holds: read-only stands.** Checked on spike-77's `ScratchDocument`, a
writable `Document` over a scratch package with a 50 MB file, a small counter file and a
subdirectory.

- **The destination is not the document's URL.** It is a sibling,
  `One.geneaspike.sb-<id>-<random>`, which the system creates before `write` runs. It is
  pre-filled with **hard links** to every file in the original, as it is on disk at that
  moment, and every directory is recreated. After `write`, the sibling replaces the
  original. The package's inode and every subdirectory's inode change, and file inodes
  are kept. No bytes are copied, which was checked on APFS only.
- **It is not per file.** The whole tree is replaced at every save.
- **Writing into a pre-linked file in place changes the original before the swap.** A
  temporary file then a rename, as `AtomicIO` does, would not.
- **Autosave fires about 15 s after a change.** A change made outside an event
  (in a `.task`) is not noticed until the next event.
- **An outside write in that window stops the autosave behind a modal alert:** "could not
  be autosaved. The file has been changed by another application", offering Save As,
  Revert and Save Anyway. *Save Anyway* kept the outside writes, because staging links
  what is on disk at save time. So the cost is the alert, not silent loss. Only an
  uncoordinated write made during `write` itself would be dropped.
- **Gotcha:** `URLDocumentConfiguration.fileURL` is main-actor isolated in the SDK, and
  `writer(configuration:)` is called off the main actor during a save. Reading it there
  with `MainActor.assumeIsolated` crashed the app (a libdispatch assertion). Carry the
  URL in the snapshot, which is built on the main actor.
