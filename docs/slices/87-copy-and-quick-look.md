# 87 — Copy and Quick Look

Specced 2026-11-27 from the [second UI audit](workstream-5-ui-audit.md) (G6, G16):
[#43](https://github.com/GeneaLogic/GeneaLogic/issues/43).

**Problem.** Edit ▸ Copy does nothing with an artifact or person selected, so a name or a
title has to be retyped into a note, a mail or a search. And Space does nothing: to look
at a file you open the artifact and click it, where Finder, Mail and Photos show it in
place.

**Layer.** App, plus one engine read for fork 4 (`trashedFileContents(ofArtifact:)`,
`trashedFileContent(_:)`: where a trashed item's bytes lie) and one entitlement (fork 3).
No format change.

## Design forks

1. **A copy, pasted as text, is one line, the way the row reads** *(agreed 2026-11-27)*.
   It is the title or display name, followed by the primary date the list shows beside
   it, in parentheses when there is one: `Letter from Karl (about 1903)`,
   `Anna Lindqvist (about 1872)`. Two of one name then stay apart. ⌘C hands SwiftUI a
   `Transferable` (`CopiedRecord`), so a later record representation goes in front of
   the text there without changing what a text paste gets.
   *Not this slice:* pasting a record into another archive, and exporting one to Finder
   ([#93](https://github.com/GeneaLogic/GeneaLogic/issues/93)). Both need format decisions. A multi-line summary is a citation in all but
   name, and that belongs with [#7](https://github.com/GeneaLogic/GeneaLogic/issues/7) (`0.3`). Putting the artifact's files beside the
   text would make a paste into Mail attach them when you wanted the title.
2. **⌘C copies the selected row of the focused list; text fields keep their own Copy**
   *(agreed 2026-11-27)*. It is wired with SwiftUI's focus-scoped `.copyable` on the
   sidebar's list (the Tree's focus is the People selection), not by replacing Edit ▸
   Copy. So a text field's selection still copies as it does now. An artifact's or a
   person's row, and a Tree card, gain **Copy** in their context menus, drawn from the
   command source like every other item (`copyArtifact`, `copyPerson`) and writing the
   same line; they have no second ⌘C binding. A **file** copies the file itself
   (`copyFile`), from its row's ⋯ and
   context menus and Artifact ▸ Selected File: a paste into Finder or Mail gets the file
   under its `originalName`, not its package path. (The file list is buttons, not a
   focusable list, so it has no ⌘C of its own.)
3. **Space and ⌘Y show the system Quick Look panel** (`QLPreviewPanel`) *(agreed
   2026-11-27)*, for the selected artifact in the sidebar. The panel opens on the file
   the detail is previewing (else the first), its arrows step through the artifact's
   files, and it follows the sidebar's selection while it is up. File ▸ **Quick Look
   “‹artifact›”** (⌘Y, Finder's) is the menu-bar item: it names the artifact, whose
   files the panel steps through. The artifact rows' and file rows' menus gain Quick
   Look too. A person has no file, so the item dims. The panel is handed copies under
   the user's filenames, made as it asks for each, never the package's own bytes.

   **Measured first, and it stalled:** images and PDFs rendered at once, but a `.docx`
   spun for 15–30 s and fell back to a file card, as `QLPreviewView` had. *The cause:*
   Quick Look draws Office files as HTML in a WebKit view hosted in the app, and
   WebKit's networking helper inherits the sandbox and exits at launch without
   `com.apple.security.network.client`. **Agreed 2026-11-27: the app takes that
   entitlement.** With it, the `.docx` renders at once. The app itself opens no
   connections, and the updater ([#68](https://github.com/GeneaLogic/GeneaLogic/issues/68)) would need it anyway. The in-pane preview
   keeps its in-process renderer; the entitlement may let it use Quick Look too, which
   is measured separately ([#94](https://github.com/GeneaLogic/GeneaLogic/issues/94)).
4. **The Trash's rows gain Quick Look** *(agreed 2026-11-27)*, from their context menus. 86 left previewing a
   trashed item to this slice, and it is the one way to see what Delete Permanently…
   would destroy. A trashed artifact previews its files from `.trash/`, read-only; a
   record-only trashed file, or a trashed artifact that had no files, has nothing to show,
   so the item dims. Trash rows have no
   selection, so there's no Space there. *The alternative:* leave the Trash out.
   **Recommended: include it.**

## Out of scope

- Paste, and a record's own pasteboard type: copying a record between archives and
  exporting it to Finder ([#93](https://github.com/GeneaLogic/GeneaLogic/issues/93)), and drag and drop
  ([#16](https://github.com/GeneaLogic/GeneaLogic/issues/16), `0.2`), which will share that type.
- Copying several rows: multiple selection
  ([#47](https://github.com/GeneaLogic/GeneaLogic/issues/47), `0.2`).
- A citation: [#7](https://github.com/GeneaLogic/GeneaLogic/issues/7) (`0.3`).
- Changing the in-pane preview. It stays in-process (`FilePreviewContent`).
  [#3](https://github.com/GeneaLogic/GeneaLogic/issues/3) (a replaced file's preview keeps its old type) is in that code: slice 65
  moved a replaced file to a fresh path, so it is re-checked here and closed if it no
  longer reproduces, or reported if it does.

## Verification

- **App tests:**
  - an artifact's and a person's copy text, with and without a primary date, and a
    person with no name;
  - the copy and Quick Look commands' enablement: Quick Look dims for a person, for an
    artifact with no files, and for a record-only trashed file;
  - the Quick Look item's title names the artifact, and only while it can run;
  - the file copy is written under `originalName`, and two copies of same-named files
    don't collide.
- **Engine test** (`swift test`, and Linux): a trashed artifact's and a trashed file's
  contents point at their staged bytes under the user's names; a record-only file has
  none.
- **Hand-test:**
  - ⌘C on a selected artifact, then on a person (People and Tree), and paste into
    TextEdit;
  - select text in a field and ⌘C: the field's text is copied, not the row;
  - copy a file from its ⋯ menu and paste into Finder and into Mail;
  - Space on an artifact with a PDF, an image and a `.docx`: the panel opens promptly,
    arrows step through the files, Space closes it;
  - ⌘Y and File ▸ Quick Look do the same; with a person selected it is dimmed;
  - Quick Look a trashed artifact from the Trash;
  - replace a `.txt` with a `.pdf` and check the preview (#3).
