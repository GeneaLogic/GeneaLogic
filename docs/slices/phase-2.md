# Phase 2 — Mac app: archive management ✅ DONE (slices 1–39 merged)

**Goal:** a SwiftUI app (`GeneaLogicApp`, an Xcode project over GeneaLogicKit) that
opens a `.genea` package and manages the archive in place — no tree/matching yet.
Hosting decision (`WindowGroup`, not `DocumentGroup`) and the window model are in
ARCHITECTURE.md §7.

**Done (merged to `main`, CI green on macOS + Linux):**
- ✅ **Slice 1** — open/create + browse a `.genea` (`NavigationSplitView` artifact
  browser; read-only detail).
- ✅ **Slice 2** — drag-in / **Add Media** ingest → `addArtifact` + `attachFile`;
  `GeneaLogicExtract` ImageIO `MetadataExtractor` wired via the Phase 1 seam;
  extracted EXIF/IPTC/GPS shown **read-only as suggestions**, never auto-writing
  `events[].date`/`locations[]` (scan-date trap, §6.4). Open → `.fileImporter`.
- ✅ **Slice 3** — `.genea` registered as a package document type (Finder open /
  `onOpenURL`; package-aware open panel).
- ✅ **Slice 4** — **multi-archive windows**: one archive per window via a
  value-based `WindowGroup(for: URL.self)` + a per-window `ArchiveModel`. Opening
  an already-open archive focuses its window (value dedup); a fresh window shows
  the welcome screen; opening from the welcome screen transforms that window in
  place, and a redundant welcome window auto-dismisses. An `ArchiveAccessStore`
  bridges security-scoped access across `openWindow`'s URL serialization;
  File-menu commands target the key window via `@FocusedValue`. Session-scoped
  (`restorationBehavior(.disabled)`); bookmark-backed relaunch restoration
  deferred. (ARCHITECTURE.md §7.)
- ✅ **Slice 5** — **metadata editor**: the detail view gets an explicit Edit/Done
  mode that buffers the full record locally and commits descriptive fields (title,
  media type, source tier, tags, language, original format, notes) in one
  `updateMetadata` write (the engine stays the sole writer; the app `refresh()`es
  the browse list after). Plus the **human-confirmed apply step** for the
  embedded-metadata suggestions: each captured EXIF/IPTC row gets an **Apply…**
  sheet that promotes the value into an `Event` or `Location` — but only after the
  human picks the target field and **corrects the value** (a 2026 scan date is
  prefilled but stays editable, never auto-applied — the scan-date trap, §6.4).
  Descriptive edits leave `provenance` untouched (it records creation); applied
  assertions ride the artifact's existing human/`asserted` provenance.
- ✅ **Slice 6** — **attach-to-existing + file roles**: the detail view gains a
  read-only **Files** list (original name, role badge, package path · format ·
  size) and an **Attach File…** menu that adds a file to the *selected* artifact
  under a chosen `FileRole` (preservation master / access copy / derivative /
  transcript), via `attachFile`. Distinct from the toolbar **+** (Add Media, which
  mints new artifacts); both multiplex the one allowed `.fileImporter` via an
  `ArchiveModel.ImportMode` enum. The file list reloads off the summary's
  `fileCount` after an attach; attach also captures embedded-metadata suggestions
  (still read-only, §6.4). Detach/replace deferred to the durability slice.
- ✅ **Slice 7** — **search**: a sidebar `.searchable` field bound to
  `ArchiveModel.searchText`, filtering the browse list through the engine's
  index-backed `artifacts(matching: ArtifactQuery(text:))`. Free text is a
  *substring* match over title + inline `transcript` + notes **plus an *exact*
  whole-tag (case-insensitive) match against `tags`** — so the box finds an
  artifact by its tag while tags stay atomic labels (`"marri"` ≠ `"marriage"`);
  the structured `query.tags` facet stays separate (the slice-13 tag-filter UI). This
  half is a small **engine** change (in `matches`, shared by the app *and*
  `genea find`), covered by a new `LookupTests` case (engine suite now 110). Blank
  query restores the full list; no matches shows `ContentUnavailableView.search`;
  the detail pane resolves the selection against *all* artifacts so narrowing the
  sidebar never blanks it. (At this point a `role: .transcript` file's text was
  not yet searched — closed in slice 8.)
- **Slice 8 — transcript editor + transcript-file search indexing.** App: a
  dedicated full-height `TextEditor` **sheet** edits the inline `Artifact.transcript`
  (deliberately omitted from the compact descriptive-fields editor), committed in one
  `updateMetadata` write — empty saves as `nil`, not `""`; the detail view shows it
  read-only with an Add/Edit Transcript… action. Engine: indexing the text of
  `role: .transcript` *files* so search covers transcripts stored as files (the
  deferral above). A new `artifact.search_text` index column (**schema v2** — the
  version bump makes existing `.index/` caches rebuild, so no `ALTER TABLE`) is
  populated at index time from each transcript file's UTF-8 text and folded into the
  `matches()` free-text haystack — read at *index* time, not per query. Best-effort:
  a binary/non-UTF-8 transcript file simply contributes nothing (the index is a
  cache, not authoritative). Shared by the app *and* `genea find`; covered by a new
  `LookupTests` case asserting file-text search **and** rebuild-losslessness (engine
  suite now 111 / 108 on Linux). Editing transcript *files* in-app is deferred (it
  needs the file-write durability work below).
- **Slice 9 — undo/redo + detach/replace file (app-layer durability).** Atomic
  writes were already structural (every write goes through `AtomicIO`; crash-safe
  temp-then-`rename(2)`); this slice adds the *user-facing* half: in-session,
  per-window `UndoManager` undo/redo for the in-place edits. Metadata/transcript/
  apply-suggestion register a **record-snapshot restore** (undo/redo are ordinary
  forward `updateMetadata` writes — the engine stays sole writer). File ops are made
  reversible in the **engine**: `detachFile`/`replaceFile` now return a `FileChange`
  after staging the bytes they would destroy into a temp dir *outside* the package
  (no un-manifested files inside it), and `revert(_:) -> FileChange` applies the
  inverse — re-adding the **exact** `FileEntry` (uid stable; path reused when free)
  or restoring prior content — returning the opposite change, so undo and redo are
  one ping-ponging call (`revert(revert(c))` round-trips). The app exposes per-file
  **Delete** (confirm dialog; undoable) and **Replace…** (via the shared importer,
  new `ImportMode.replace`); the detail pane reloads off a `mutationVersion` so an
  undo/redo originating in the model visibly refreshes fields/transcript/files.
  +3 `FileNamingAndAttachmentTests` round-trip cases (attach/detach/replace undo +
  redo: bytes, uid, sha256, manifest faithful); engine suite now 114 / 111 on Linux.
  **In-session only** (no persisted journal); `Add Media` (new-artifact ingest) is
  not yet on the undo stack.
- **Slice 10 — delete artifact (undoable).** Extends slice 9's undo foundation one
  level up: a sidebar context-menu **Delete Artifact…** + confirm dialog (title +
  file count + undo hint). The engine's `removeArtifact(_:)` is now reversible —
  `removeArtifact(_:) -> ArtifactDeletion` stages the **whole** artifact folder
  (record.json + every file) into a temp dir *outside* the package before deleting,
  and `restoreArtifact(_:)` copies it back and re-inserts into the index (transcript
  `search_text` reprojected) + manifest. `uid` is faithful; the slug is reused when
  free, else reassigned. **Hard-delete + in-session undo, not a persisted tombstone**
  (a `deleted`-flag/Trash model would be a format change touching the §5.1 surface —
  deferred). Conclusions are deliberately **not** rewritten (dangling
  `EvidenceLink`/`PersonMention`s are `verifyIntegrity()`'s job, §2.3) — which is also
  what makes the delete cleanly reversible (restoring re-validates any links). A
  deleted selection falls back to the detail placeholder on its own. +1
  `ArtifactCRUDTests` round-trip case (delete → restore → redo: record + all files +
  manifest + index/search faithful); engine suite now 115 / 112 on Linux.
- **Slice 11 — integrity panel.** Surfaces the engine's already-built
  `verifyIntegrity()` in the app: File ▸ **Verify Integrity…** (`@FocusedValue`-targeted
  at the key archive) opens a sheet that runs the check from a `.task` — yielding once
  so the spinner paints before the synchronous, main-actor SHA-256 sweep — and shows
  either an **"Archive Is Intact"** state or the `IntegrityReport.Issue`s grouped into
  **Corruption** (checksum / missing / size mismatch — real data problems, red) vs.
  **Stray Files** (`unreferencedFile` — informational, orange), each row carrying the
  package-relative path + a one-line explanation. Actions: **Re-run** and **Rebuild
  Index** (`rebuildIndex()` — the safe §5.1 out-of-band-edit fix; deliberately **not**
  undoable, since it regenerates the disposable `.index/` cache and never touches a
  record). `repair()` stays unsurfaced (it's an honest throwing stub); dangling-
  reference detection (`findDanglingReferences()`, unbuilt) is deferred to the Phase 3
  conclusions UI, where a dangle can actually be created in-app. **Pure app-layer** —
  no engine change, so the test counts are unchanged (115 / 112 / 6); manual UI testing
  is the net (clean state, both issue groups against a corrupted/strayed archive,
  re-run-after-repair, rebuild). Implementation note: a `.sheet` reading
  `@Environment(ArchiveModel.self)` must have the model injected **on the sheet's own
  content** when the `.sheet` modifier sits outside the `.environment(model)` injection
  — sheets inherit environment from where the modifier is attached, not from the
  presenter's descendants (the other sheets work because they present from inside the
  detail view, under the injection).
- **Slice 12 — relaunch persistence (bookmarks + Open Recent + OS window restore).**
  The app remembers archives across launches via **app-scoped security-scoped
  bookmarks** — a restored `URL` window-value carries no live sandbox scope, so this
  re-derives one. New `com.apple.security.files.bookmarks.app-scope` entitlement (an
  explicit `GeneaLogicApp.entitlements` now backs the previously build-setting-only
  sandbox config). New `ArchiveBookmarks` (`@Observable`, `UserDefaults`-backed)
  persists, per archive, a bookmark + a recents list; `ArchiveAccessStore` gains
  `ensureAccess(to:)`, which `ArchiveModel.load()` calls before opening so a
  reopened/restored window re-acquires access (failing to a clear "can no longer reach
  this archive" state, and self-pruning the dead bookmark). Surfaces: **File ▸ Open
  Recent** (updates live off the observable store; Clear Menu keeps bookmarks) and
  **window restore across relaunch**, handed to the **OS**
  (`restorationBehavior(.automatic)`) so it correctly honors the user's "Close windows
  when quitting an app" setting rather than overriding it (clean-slate users get a
  clean slate; restore users get their windows back, access re-derived from bookmarks).
  **macOS-14+ gotcha (cost a detour):** SwiftUI window restoration is silently disabled
  unless an `NSApplicationDelegate` returns `true` from
  `applicationSupportsSecureRestorableState` — the first attempt restored nothing and
  was *mis*diagnosed as the system setting suppressing it (and as a duplicate-window
  bug, which turned out to be stale accumulated saved state from repeated force-quits);
  a sandboxed app's saved state also lives in its *container*, not
  `~/Library/Saved Application State/`. **Pure app-layer** (test counts unchanged:
  115 / 112 / 6); verified by quit-and-relaunch (clean-slate = welcome only;
  forced-keep = exactly the windows that were open, no dupes), Open Recent, and the
  moved/deleted-archive path.
- **Slice 13 — tag-filter UI.** A toolbar **Filter** menu (`TagFilterMenu`) lists every
  tag in the open archive as a `Toggle` with its artifact count, driving the **structured**
  `ArtifactQuery.tags` facet (exact, whole-tag, AND-combined) *in the same query* as the
  §5.1 free-text search — so text and tags AND together. `ArchiveModel` gains
  `selectedTags`, a `tagFacets` count derived from the loaded `ArtifactSummary.tags` (no
  extra query), a unified `applyFilters()` (replacing the text-only `search()`),
  `isFiltering`, and `toggleTag`/`clearTagFilter`; `refresh()` prunes a selected tag that
  no longer exists so the filter can't stick on a vanished tag. The label is title+icon
  ("Filter" → "Filter (N)", filled icon while active — a toolbar menu otherwise collapses
  to icon-only and loses the count) and is **disabled** when the archive has no tags; a
  filter matching nothing shows a distinct "No Matches" state. **Pure app-layer** — the
  engine's `query.tags` already did exact AND filtering, deliberately kept separate from
  free text for exactly this (test counts unchanged: 115 / 112 / 6). Verified in the app:
  per-tag narrowing, two-tag AND, tag-AND-search, the count badge, Clear Filters, the
  No-Matches state, and the disabled state on a tagless archive.
- **Slice 14 — Add Media on the undo stack.** `ingest` (new-artifact ingest, the `+` /
  drag-in path) is now undoable — the last unreversible mutation, so the in-session undo
  story is complete. Adding an artifact is the inverse of deleting one, so this **reuses
  the reversible-delete machinery**: each created artifact registers a "delete me" undo
  (`registerArtifactRedelete`, now `actionName`-parameterized and shared with the delete
  path's restore side), so ⌘Z removes it via `removeArtifact`→`ArtifactDeletion` (folder
  staged outside the package) and ⌘⇧Z restores it uid-faithfully via `restoreArtifact`. A
  multi-file Add Media registers one redelete **per** new artifact, but the whole batch
  runs in one run-loop event so the window's `UndoManager` **event-groups** them — one ⌘Z
  reverts the entire batch, one ⌘⇧Z restores it (the grouping the multi-file Attach path
  already relies on). **Pure app-layer**, no engine change (test counts unchanged:
  115 / 112 / 6). Verified in the app: single- and multi-file add undo/redo (uid + file
  faithful), the "Add Media" action name, and per-window isolation.
- **Slice 15 — file preview & export.** The detail pane's Files list is
  selectable (each row a full-row `.plain` `Button`, leading icon + hover/selection
  highlight + a hint); selecting a row opens a **preview pane beside the metadata** in an
  `HSplitView` (the split's native divider resizes it), with a header carrying pop-out +
  close. Preview rendering is **type-dispatched in-process** (`FilePreviewContent`: `Image`
  for images, `PDFView` for PDFs, `QLPreviewView` only as fallback) — `QLPreviewView` is
  avoided for the common types because its **out-of-process** remote view makes a click into
  a preview window stall on the XPC hit-test (the giveaway: slow on click, fine via ⌘`); the
  in-process path is instant. A **pop-out** button opens the file in its own window
  (value-based `WindowGroup(for: FilePreviewRequest.self)`, restoration disabled), and the
  per-file ⋯ menu gains **Quick Look**, **Open in Default App**, **Save a Copy…**
  (`NSSavePanel`), and **Open in Separate Window**. The inline preview reads the package file
  directly through a new read-only engine accessor **`fileURL(of:in:)`** (the app holds the
  archive's security scope); anything leaving the app (pop-out, Open in Default App) gets a
  **session-temp copy** (`ArchiveModel.temporaryCopy`) and Save a Copy writes to the chosen
  location (`exportFile`), so the **package original is never exposed**. One engine change
  (the accessor, +1 test → 116 / 113 / 6); the rest app-layer. Verified in the app: image
  preview, side-by-side resize, pop-out (instant fronting), Open in Default App, Save a Copy
  (byte-identical copy, original untouched), and selection clearing on artifact switch.
- **Slice 16 — detail-view field coverage + manual event/place entry.** Read-only
  detail now mirrors *every* descriptive field and stops leading with internal IDs: it shows
  **Language / Original Format / Notes when filled** (read off the full record loaded in the
  same `.task` as files/transcript), moves **UID/Slug** into a de-emphasized **Identifiers**
  group at the bottom, and shows **Primary Date** *only when present*, captioned "earliest
  event date" and **read-only** — it's *derived* (the earliest of the events' dates, §2.3),
  not a stored field, so it deliberately stays uneditable. The substantive fix is a new
  **Events & Places** section that makes `events`/`locations` **visible** and **addable
  without a suggestion** — closing the gap that a date absent from a file's metadata had no
  way in. The suggestion-only `ApplySuggestionSheet` becomes `AssertionEditorSheet` with a
  `Prefill` enum: `.suggestion(entry)` preserves the §6.4 scan-date-trap path (captured-value
  row, event/place picker, corrected value), while `.blankEvent` / `.blankPlace` start empty
  for manual entry. Both add paths and a per-row trash **remove** write through
  `updateMetadata`, so each change is **undoable** (⌘Z); removal is by array index against the
  loaded snapshot, bounds-checked inside the mutation. Pure app-layer, no engine change
  (counts unchanged: 116 / 113 / 6). Verified in the app: field coverage, Add Event/Place,
  derived Primary Date, and undo/redo of add + remove.
- **Slice 17 — on-demand embedded-metadata re-scan.** A per-file **⋯ ▸ Scan for
  Metadata** re-runs the `GeneaLogicExtract` extractor against the **already-stored** file
  (read in-process via slice 15's `fileURL(of:in:)`, no temp copy) and drops any embedded
  metadata into the session `capturedMetadata` cache — so the read-only **Embedded Metadata
  (Suggestions)** section and its **Apply…** (the slice-16
  `AssertionEditorSheet.Prefill.suggestion` path) work for files added in a *prior* session,
  not just this one, lifting the session-only limit on *seeing* suggestions. Nothing is
  persisted or auto-applied — re-scan only repopulates the in-memory cache, keeping the §6.4
  scan-date trap intact; promotion still goes through the human-confirmed Apply step. A file
  with no extractable metadata reports via a new benign `actionInfo` alert (distinct from the
  `actionError` channel). Pure app-layer — reuses the `fileURL` accessor + the
  `MetadataExtractor` protocol, no engine change (counts unchanged: 116 / 113 / 6). Verified
  in the app: re-scan resurfacing EXIF on a prior-session image, Apply opening the
  suggestion-prefilled sheet, and the "no metadata found" path on a non-image file.
- **Slice 18 — restore selected artifact on relaunch.** The per-window artifact
  selection (previously in-memory `@State`) becomes `@SceneStorage("selectedArtifactID")`, so
  it rides the same state-restoration machinery as the window (slice 12) and returns when a
  window restores. Stored as the id's raw string (scene storage holds only scalars), bridged
  to an `ArtifactID?` binding; per-scene, so each archive window restores its own selection,
  and a stored id whose artifact was deleted falls back to the placeholder. Deliberately
  scoped to *selection only* — search text / tag filters / preview-file could ride the same
  pattern but were deferred (reopening into a filtered list risks a "where did my artifacts
  go?" surprise; edit mode, open sheets, and §6.4 suggestions should never restore). Pure
  app-layer, no engine change (counts unchanged: 116 / 113 / 6). Verified in the app: select
  → clean quit → relaunch restores both the window and the selection.
- **Slice 19 — persons-mentioned editing.** A new **Persons Mentioned** section in the detail
  view makes `Artifact.personsMentioned` visible and editable — the natural companion to the
  slice-16 Events & Places work, and the first evidence-layer input the Phase 3 relationship
  inference will read. Each `PersonMention` is recorded as it appears in the document: name as
  recorded, role (subject / informant / witness / parent / spouse), information quality
  (primary / secondary / undetermined), and an optional "age as recorded"
  (`attributes["ageAsRecorded"]`). The `AssertionEditorSheet` (née apply-suggestion sheet)
  grows a `.blankPerson` prefill alongside `.blankEvent`/`.blankPlace`; the record-local
  `localRef` is **auto-minted** at write time (lowest unused `p<n>`), never user-entered, so a
  future `EvidenceLink` has a stable anchor. Add and per-row remove both write through
  `updateMetadata`, so they're undoable (⌘Z) like every other edit; a removed `localRef` may
  leave a dangling link for `verifyIntegrity()` (§2.3) — conclusions are untouched. Strictly
  **evidence-layer**: a `PersonMention` is "the name as it appears here," never a tree
  identity; resolving a mention to a concluded `Person` and asserting relationships stay Phase
  3. Pure app-layer (the model has carried `personsMentioned` since Phase 0), no engine change
  (counts unchanged: 116 / 113 / 6). Verified in the app: add (with role/quality/age) →
  persisted `localRef p1` + `attributes`; second add → `p2`, empty age omits `attributes`;
  subtitle hides quality when undetermined; undo/redo faithful; per-row trash removes.
- **Slice 20 — persisted trash for deleted artifacts.** Deleting an artifact now moves its
  folder into a reserved in-package **`.trash/<uid>/`** (a `payload/` + a `deletion.json`
  sidecar) *before* the index/manifest forget it, so a delete survives quit and is recoverable
  across sessions — not just by in-session ⌘Z. A new **File ▸ Show Trash…** sheet lists trashed
  artifacts (title + deleted-when) with **Restore**, per-row **Delete Permanently**, and
  **Empty Trash** (the last two irreversible). Engine: `removeArtifact` stashes into the trash
  (atomic rename within the package) instead of a temp dir, and `restoreArtifact` (the ⌘Z path)
  becomes a thin alias over the new `restoreFromTrash(_:)` — **⌘Z and the Trash UI are two views
  on the same store**, so undoing a delete also consumes its trash entry; plus
  `trashedArtifacts()`, `deleteFromTrash(_:)`, `emptyTrash()`. A **kind-agnostic `TrashStore`**
  owns the filesystem mechanics, and `deletion.json` (the `TrashEntry` model record) carries a
  **`kind` discriminator** (`.artifact` today) so extending the trash to detached *files* later
  needs no format migration — only a `.file` case + a re-attach restore path. `.trash/` is a
  top-level **reserved** sibling of `artifacts/` (joining `.index/`), so it's invisible to the
  manifest, the index rebuild, and `verifyIntegrity()` — `rebuildIndex()` can't resurrect a
  trashed artifact (regression-tested). Conclusions untouched (§2.3). Engine change, Linux-
  verified (124 / 121 engine + 6 CLI). Verified in the app: delete → quit → relaunch → Show
  Trash still lists it → Restore brings it back; in-session ⌘Z restores *and* clears the entry;
  Empty Trash permanently purges; integrity clean throughout.
- **Slice 21 — persisted trash for detached files.** The per-file **Delete** (detail-pane
  ⋯ ▸ Delete) is now trash-backed, the file analog of slice 20: `detachFile` **moves the file's
  bytes into `.trash/<FIL-uid>/`** (keyed by the file's own uid) instead of the old temp-staging,
  so a deleted file survives quit and is recoverable across sessions. It reuses the **same
  `.trash/` store** via the `TrashEntry.kind` discriminator — now a live **`.file`** case beside
  `.artifact`, with a new `FileTrashInfo` carrying the full `FileEntry` + owning
  `artifactUID`/title — *exactly the forward-design slice 20 left room for, cashed in with no
  format migration*. Engine: `detachFile`→trash (a record-only entry when the bytes were already
  gone out-of-band), new `restoreFile(_:)` (re-attaches to the owning artifact, reuses the
  original path when free, throws `fileTrashEntryNotFound`/`artifactNotFound`), `trashedFiles()`,
  `deleteFileFromTrash(_:)`; `emptyTrash()` already clears both kinds. `FileChange.removed`
  dropped its in-session temp `stagedBytes` (the bytes now live in trash, found by uid), so
  `revert` of a `.removed` restores from trash — **⌘Z and the Trash UI are two views on one
  store**, like artifacts. **Out of scope by design:** `replaceFile`'s prior content stays
  in-session temp (swapping content isn't deleting a file, and trashing every prior version would
  clutter the Trash). App: the **Show Trash** sheet grew an **Artifacts** + **Files** two-section
  layout (shared Empty Trash); Trash-sheet **Restore is itself undoable** (⌘Z re-detaches), and a
  stale undo/redo whose bytes were permanently removed **no-ops gracefully** via `showInfo(_:title:)`
  ("Can't Restore File"). Conclusions untouched (§2.3). Engine change, Linux-verified (133 / 130
  engine + 6 CLI). Verified in the app: delete file → moves to `.trash/` (kind `file`) → Restore
  re-attaches; ⌘Z of a restore re-detaches; Empty Trash purges; stale ⌘Z shows the benign notice
  (no crash); survives quit → relaunch → still in Trash.
- **Slice 22 — vendored-SQLite hygiene (bump + freshness automation).** The in-tree SQLite
  amalgamation (`GeneaLogicKit/Sources/CSQLite`, the `.index/` driver) was a *stale incidental
  pin*: the Phase 1b spike deliberately chose to **vendor** the amalgamation (for cross-platform
  version determinism + compile-flag control), but the specific **3.46.1** was just whatever was
  on hand — already ~22 months old the day it was committed, with no compatibility reason to hold
  it. Bumped to **3.53.3** (current upstream). New **`scripts/update-sqlite.sh`** fetches the
  latest amalgamation and **verifies its SHA3-256 against sqlite.org's machine-readable product
  data** before any bytes touch the repo (supply-chain integrity), swaps `sqlite3.c`/`sqlite3.h`,
  and rewrites the README version/URL; a monthly **`sqlite-freshness`** GitHub workflow compares
  the pinned version against upstream and opens a deduplicated tracking issue when behind (so
  security fixes aren't missed by memory — Dependabot can't track a vendored C file). Practical
  exposure was always low (the engine only opens its own **rebuildable** `.index/index.sqlite`,
  never untrusted DB files; all SQL is bound-parameter with `SQLITE_DQS=0`), but staying current
  is cheap hygiene. No schema or migration — the index is a rebuildable cache. Engine change,
  Linux-verified; macOS + Linux + app all green on 3.53.3 (133 / 130 engine + 6 CLI, unchanged).
- **Slice 23 — Continuity Camera scan ingest**. Scan a document with a nearby
  iPhone/iPad and drop it straight into the archive, for **both** a new artifact (the toolbar
  `+` pops **one connected AppKit menu**: *Add Media…* above the Continuity *Take Photo* / *Scan
  Documents*) and an existing one (the detail **Attach File…** menu gains a *Scan with iPhone or
  iPad…* submenu, per `FileRole`). macOS delivers Continuity Camera through the **NSServices
  responder chain**, not a callable picker: a zero-size `ContinuityCameraReceiver` (`NSView` +
  `NSServicesMenuRequestor`), hosted in the window and made first responder, returns itself from
  `validRequestor(forSendType:returnType:)` for image/PDF return types, so AppKit auto-inserts the
  scan items into the menu we present. **Three hard-won AppKit facts:** (1) present via
  **`NSMenu.popUpContextMenu(_:with:for:)`** (a bare `popUp` pops an *empty* menu — AppKit only
  inserts through the contextual-menu path); (2) **defer to the next runloop turn** (a SwiftUI
  menu/button may still be dismissing — can't open a menu session while one tracks); (3) AppKit
  **always inserts the items flat**, so Finder's nested "Import from iPhone ▸" submenu is **not
  reproducible** via the public API — the UI is one flat-but-connected menu. The capture arrives in
  `readSelection(from:)` as a **multi-page PDF** (scan) or image (photo → PNG); received bytes go to
  a session-temp file funneled through the **existing** `ingest`/`attach` paths — so a scan is
  metadata-extracted and **undoable** (⌘Z) like Add Media / Attach — then the temp file is removed
  once the engine has copied it in. `ArchiveModel` stays AppKit-free (reaches the scanner via a
  UI-free `ContinuityScanning` protocol). **Pure app-layer; no engine change, no new entitlement.**
  *Scope:* Continuity Camera only — USB/network scanners (ImageCaptureCore) were deferred (see
  below). *Testability:* menu wiring + no-device no-op verified live; the iPhone→Mac handshake
  itself is a human live-device test.
- **UI refinement (audit-driven).** A read-only UI audit ([`UI-AUDIT.md`](../UI-AUDIT.md)) triaged the
  app's surfaces into a prioritized backlog (F1–F14: macOS HIG, SwiftUI idiom, intuitiveness) before
  the Phase 3 transition; worked slice by slice.
  - **Slice 24 — document-primary layout + metadata inspector (audit F2, Slice A).** Flipped the
    artifact detail view from a metadata-first scrolling stack to **document-first**, the natural
    paradigm for a document-first DAM. The detail pane now shows the artifact's **document** (the
    primary file's in-process preview), with a **file-selector strip** for multi-file artifacts
    (auto-selecting the first `preservationMaster`, else the first file) and a **No Files Yet** empty
    state for metadata-only artifacts; all metadata (descriptive fields, Events & Places, Persons
    Mentioned, Transcript, Files management, embedded-metadata suggestions, Identifiers) moved into a
    **toggleable trailing `.inspector()`** (toolbar `info.circle` toggle, à la Preview; visibility persisted per
    window via `@SceneStorage`). **Edit/Done is preserved**, now inside the inspector so the document
    stays visible while editing; file selection syncs both ways between the strip and the inspector's
    Files list. Pure app-layer, no engine change. *(In-flight fix: don't nil the file selection in
    `onChange(of: artifact.uid)` — it races the `.task` that re-derives the primary file.)*
    **Slice B (audit F3, pending):** always-editable commit-on-blur inspector, retiring Edit/Done.
  - **Slice 25 — sidebar rows show metadata, not the UID (audit F1).** The browse-list row subtitle
    was the raw `ART-…` UID (developer addressing); it's now `primary date (when present) · source
    tier · media type` — the genealogically useful facets, blanks omitted. Trivial app-only change.
  - **Slice 26 — always-editable inspector (audit F3, Slice B).** Retired the Edit/Done mode: the
    inspector's descriptive fields are now live controls that **commit on blur or Return** (pickers
    on change), each its own undoable write fired only on a real change. Required Title reverts if
    blurred empty; derived Primary Date stays read-only; the live buffers re-seed from the record on
    undo/redo. Undo is now per field. Pure app-layer. *(macOS note: clicking empty whitespace doesn't
    blur a TextField, so a commit lands on focus moving to another control or on Return.)*
  - **Slice 27 — resizable sheets (audit F5).** The four sheets (Assertion editor, Transcript
    editor, Integrity report, Trash) were fixed-size and non-resizable. Fix: `.presentationSizing(.fitted)`
    + a `min`/`ideal`/`max` content frame on each. *(Gotcha: macOS 15 made SwiftUI sheets fixed-size
    by default — a flexible frame alone adds no drag handle, verified live; `.fitted` is the
    documented opt-back-in, no AppKit needed.)* The transcript `TextEditor` dropped its fixed floor
    to fill the growable sheet. Pure app-layer.
  - **Slice 28 — sidebar list-controls cluster + sort (audit F7 + F14).** Moved the tag filter out of
    the trailing toolbar into a `ListControlsBar` pinned under the sidebar search field
    (`.safeAreaInset(.top)`): Filter + a new Sort menu, co-located with the search they combine with;
    the trailing toolbar keeps only the `+`. Sort (F7) is client-side over the loaded summaries —
    title / date-added (by time-ordered UUIDv7) / primary date (ISO string, undated last both ways),
    stable title→uid tiebreak, per-key direction labels. In-memory sort state (not restored), default
    `.title` ascending = the existing order. Pure app-layer.
  - **Slice 29 — new artifact ends up selected.** Creating an artifact (Add Media, drag-in,
    Continuity scan-new) now auto-selects it so its document/inspector shows at once, instead of
    leaving the pane on "Select an Artifact." `ingest` publishes a one-shot `lastCreatedArtifact`
    intent; the container moves the scene-stored selection there. Undo (⌘Z) removes the artifact and
    the pane falls back to the placeholder. Pure app-layer.
  - **Slice 30 — zoomable non-PDF previews.** Image previews now zoom/pan on par with PDFs:
    the image branch renders through an `NSScrollView` with `allowsMagnification` (the same native
    mechanism `PDFView` uses) — pinch to zoom (1×–16×), scroll to pan, `magnification 1` = fit-to-
    window (refits on resize). The pop-out preview window gets it too. Pure app-layer.
  - **Slice 31 — duplicate window on relaunch.** Double-clicking a `.genea` that was restored
    on launch spawned a second window. Two causes: (a) `WindowGroup(for: URL.self)` dedups by URL
    equality, but a package's trailing-slash URL (Finder's `onOpenURL`) isn't `==` to the restored
    value — fixed by a `URL.canonicalArchiveURL` applied at every window-value entry point; (b) a
    restoration-vs-`openWindow` race no `WindowGroup` API can dedup — fixed by **deferring** the Finder-open
    (`ArchiveOpenCoordinator`) until after `applicationDidFinishLaunching`, so a single `openWindow(value:)`
    focuses the already-restored window (bringing a background archive to the front) instead of spawning a
    duplicate — replicating how the document architecture processes an open after restoration. A slim
    first-wins `ArchiveAccessStore` registry (`claimWindow`/`resignWindow`, owner-gated release) is a safety
    net. Scene state (selection, window size) is preserved because the restored window is the one kept. Pure
    app-layer.
  - **Slice 32 — consistent file-role control.** Role assignment was inconsistent and one-way: a new
    artifact's first file was hard-set to preservation-master with no way to change it; attach-to-existing
    made you *pre-pick* a role before the file existed (and the Continuity scan path pre-picked then popped a
    second, disconnected menu); and no engine call to correct a role existed at all. Fix: **one default
    everywhere + change it later.** New engine `setFileRole(_:in:to:) -> FileRole` (returns the prior role for
    undo; metadata-only, content/uid/path untouched) — the triage pass's only engine change, Linux-verified.
    App: ingest and attach both default to `preservationMaster` (the pre-pick removed), corrected afterward via
    a per-file **⋯ ▸ Role** submenu (undoable). Also folded in the **Continuity-menu disconnect** on attach —
    which turned out structural (a SwiftUI menu popping a *second* AppKit menu), not about roles: the attach
    paperclip now routes through the *same* one-connected-menu path as the `+` (`beginAttachOrScan`), so it's a
    single menu (macOS even nests the scan items under an *Import from iPhone or iPad ▸* submenu). Overlaps
    UI-audit **F8** (role-control half).
  - **Slice 33 — recent archives on the welcome screen (UI-audit F4).** `WelcomeView` was an icon + two
    buttons; the archives the user had opened were reachable only through File ▸ Open Recent. It now shows a
    **Recent** section below the buttons — one row per bookmarked archive (icon + name over its
    tilde-abbreviated folder, hover highlight), capped at 5 rows and scrollable, hidden when empty, reading
    the `@Observable` `ArchiveBookmarks` so it updates live. Clicking a row transforms the welcome window in
    place into the archive (the same `url`-binding write Open/New use) after re-deriving sandbox access from
    the bookmark; a moved/deleted archive shows the existing "Couldn't Open Archive" state and self-prunes.
    Reopening a recent (welcome list *or* File ▸ Open Recent) bumps it to the top (TextEdit-style) via a new
    bookmark-free `ArchiveBookmarks.promote`, on success only. A per-row context menu adds **Show in Finder**
    and **Remove from Recents**. Sandbox gotcha:
    `abbreviatingWithTildeInPath` keys off the container home, so the true home comes from `getpwuid`. Pure
    app-layer, no engine change. Deferred: drag-a-`.genea`-onto-the-window (a distinct mechanism).
  - **Slice 34 — consistent section affordances + unified hover-row chrome (UI-audit F8-remainder).** The
    detail-view section-header "add" controls were four different looks — Events & Places a bright borderless
    `Menu`, Persons Mentioned and (found only live) **Transcript** bordered push buttons, Files a dim
    borderless button. They're now one bright, leading-icon family from a shared `AddAffordanceLabel` (icon +
    title, plus a trailing chevron when the control opens a menu). The lesson (three brightness iterations):
    don't layer `.foregroundStyle` on a style that imposes its own — `.borderless`/`.borderlessButton` mute the
    label (read as disabled) and don't yield to `.primary`, while `.menuStyle(.button)` renders bright, so
    mixing them mismatched. Fix: `.buttonStyle(.plain)` on all four (Events `Menu` via `.menuStyle(.button)` +
    `.buttonStyle(.plain)`) imposes no color, so the label's `.primary` is the single source of appearance; and
    `.plain` renders the custom label faithfully, so the shared chevron shows on both menu-poppers. The chevron
    marks the menu-poppers (Events "Add…", Files "Attach File…") vs. the direct-action buttons (Add Person…,
    Add/Edit Transcript…) — the Files chevron was the user's ask. The Embedded-Metadata **Apply…** stays a
    `.link` (a per-row action, a different control class). The copy-pasted hand-rolled row chrome (padding + rounded hover/
    selection fill) in `AssertionRow`, `FileRow`, and `RecentArchiveRow` folded into one shared
    `.hoverRowBackground(isHovering:isSelected:)` modifier. Reframe (agreed): the audit's "move rows to `List`"
    half is **not taken** — nesting `List`s in the inspector's `ScrollView` (slice 24) is a SwiftUI
    anti-pattern; the keyboard-traversal it would buy is F6's job via `.focusable`. Pure app-layer, no engine
    change.
  - **Slice 35 — menu bar + ⌫-delete + no window tabbing (UI-audit F6, part 1 of 2).** The app was
    click-driven — most artifact actions lived only as in-pane buttons, off the menu bar and shortcut-less.
    Added a **View** menu (Show/Hide Inspector ⌘⌥I with a dynamic label; Sort By = the F7 keys + per-key
    Ascending/Descending, bound to the model's `sortKey`/`sortAscending`) and a top-level **Artifact** menu
    (Add Event/Place/Person, Edit Transcript, Attach File, a **Selected File ▸** submenu = Open in Separate
    Window / Open in Default App / Save a Copy… / Replace… / Delete File…, and **Delete Artifact… ⌘⌫** —
    Finder's Move-to-Trash, apt since delete is trash-backed). (Post-review: Attach File… goes straight to the
    importer, not the disconnected Continuity menu; the redundant Show Preview / per-file Quick Look items were
    removed since the document always previews the selection — resolving audit F10 by deletion.) **Add Media → Add Artifact** everywhere
    user-facing (distinguishing creating an artifact from attaching a file); ⌘I stays Add Artifact (inspector
    took ⌘⌥I, avoiding the Get-Info collision). **⌫ deletes the selected artifact** via `.onDeleteCommand`,
    raising the same confirm as ⌘⌫/context-menu. **Routing:** the menu `Commands` can't see the view-owned
    selection, so `ArchiveModel` gained read-only mirrors (`selectedArtifact`/`selectedFile`/`inspectorVisible`)
    the views push down + one-shot intents (`pendingArtifactCommand`/`pendingFileCommand`/`pendingArtifactDeletion`/
    `pendingInspectorToggle`) a view observes to drive its *existing* sheet/confirm state — the established
    `lastCreatedArtifact` intent pattern; no sheet code moved. **Gotchas (caught live):** `.disabled` on a
    submenu `Menu` doesn't gray its *title* (AppKit grays it only when every child is individually disabled →
    moved `.disabled` onto an inner `Group`); the transcript sheet lived inside `inspectorContent` so Edit
    Transcript with the inspector hidden wouldn't present → hoisted to the top-level body. **Window tabbing
    removed** (`NSWindow.allowsAutomaticWindowTabbing = false`): our value-based `WindowGroup` windows aren't
    tabbable and the Show Tab Bar/Show All Tabs machinery crashed. Pure app-layer, no engine change; every menu/
    shortcut/enablement/routing path live-verified.
  - **Slice 36 — focus-ring visibility + keyboard/a11y polish (UI-audit F6 part 2 of 2; resolves F11).** Live
    testing reshaped the slice: two of F6's three named keyboard gaps were **already framework-handled** — sheets
    auto-focus their first text control (typed into Add Event / the transcript editor without clicking), and a
    focused multi-line `TextEditor` already treats plain Return as a newline (Save's `.defaultAction` was merely
    *shadowed* while editing). So the work was: **(A)** the `AssertionRow` remove button was `.opacity(0.55)` until
    hovered — invisible (ring and all) to a Full-Keyboard-Access user — now revealed on `isHovering ||
    removeFocused` via a per-row `@FocusState` (dim → full + focus ring on Tab, live-verified); **(B)**
    `.accessibilityLabel` on the image-only controls VoiceOver read as just "button" (trash → "Remove", `FileRow` ⋯
    → "File actions", the pop-out → "Open in separate window"; the `+` and inspector toggle already carry titles) —
    **closing F11**; **(C)** the transcript Save moved from `.defaultAction` to `.borderedProminent` +
    `.keyboardShortcut(.return, modifiers: .command)` — plain Return stays the newline key, **⌘Return** commits
    (Xcode commit-sheet precedent), button stays prominent. **Not done (deliberate, per slice 34):** rebuilding
    `List`-style arrow-key row navigation — FKA already tabs the buttons; the gap was the dim/unlabeled ones. Pure
    app-layer, no engine change; ARCHITECTURE.md untouched (no architectural surface); A/B/C live-verified.
  - **Slice 37 — EDTF dates (engine; part 1 of 2).** Genealogical dates are usually uncertain and plain
    ISO 8601 can't express "about 1920", "1900–1905", or "before 1950". Adopted **EDTF** (ISO 8601-2 / LoC),
    Level 0 + genealogical Level 1 (`~`/`?`/`%` qualifiers, intervals `1900/1905`, open ends `../1950` /
    `1920/..`, unspecified digits `192X`/`19XX`). EDTF is a strict **superset** of the stored ISO dates, so
    it's a grammar widening — no data migration, no format-version bump. `Event.date`/`PersonFact.date` stay
    verbatim `String?`; a Foundation-free `EDTFDate.parse` derives `[lower, upper]` bounds + qualification,
    never stored. No index/schema bump (dates decode from `json`). Both engine consumers were generalized
    through the one bound API: `primaryDate`'s `earliestDate` moved from a lexicographic `.min()` to a
    bound-aware min (so `19XX` sorts before `1920`), and `dateRange` filtering moved from a leading-year
    prefix to interval overlap (`overlaps(years:)`). /code-review caught a masked-year Feb-29 bug
    (`200X-02-29`), fixed via a bounded valid-placement scan. Engine change → Linux-verified (166 macOS /
    163 Linux + 6 CLI). Spec §3 + ARCHITECTURE updated (event dates → EDTF; timestamps stay ISO 8601).
  - **Slice 38 — EDTF dates (app + a shared model helper; part 2 of 2, delivering UI-audit F12).** The
    human-facing half: dates *entered* forgivingly and *shown* readably. (1) A new **`EDTFDate.humanDescription`**
    (model, Foundation-free, Linux-tested) glosses stored EDTF — `1920~` → "about 1920", `1900/1905` → "1900 to
    1905", `../1950` → "on or before 1950", `192X` → "1920s", `19XX` → "20th century" (a masked century phrased
    distinctly from a decade), `1920-05-12` → "12 May 1920" (locale-free, GEDCOM day-month-year) — rendered from
    the string's *structure* (bounds discard precision). Wired into event rows, the Primary Date caption (canonical
    EDTF shown alongside when the gloss differs), and the sidebar row subtitle, each falling back to raw for free
    text. (2) A new **`EDTFDate.normalizingShorthand(_:)`** rewrites common idioms to canonical EDTF on commit
    (`abt/about/c./ca/circa 1920` → `1920~`, `bef/before 1950` → `../1950`, `aft/after 1920` → `1920/..`,
    `1900-1905` & `between 1900 and 1905` → `1900/1905`, month-name dates `June 1920`/`April 3, 1975` →
    `1920-06`/`1975-04-03`, decades `1940s` → `194X`, lowercase `192x` → `192X`); conservative + **output-validating** (a rule keeps its
    rewrite only if the candidate `parse`s, else free text — so `April 31, 1975` and `3 5 1975` stay free text). (3) The Add-Event Date field gained an EDTF prompt +
    a **live, non-blocking gloss** ("→ about 1920" / "stored as text"), never disabling Add. (4) The app's Primary
    Date **sort** (from slice 28) now orders by `parse(...)?.sortBound`, so `192X` (1920) sorts before `1921`.
    /code-review (3 finders) caught the normalizer validating each rule's *operand* not its *output* (`about 1920/..`
    → unparseable `1920/..~`); fixed at the root by validating the emitted candidate, plus a widened round-trip
    test. Model change → Linux-verified (176 macOS / 173 Linux + 6 CLI). No format/schema/index change (derived
    helpers only; spec + ARCHITECTURE untouched). Resolves audit **F12**.
  - **Slice 39 — named layout metrics (F13, the last UI-audit item).** The scattered magic-number content
    widths / sheet sizes / small chrome (`420`/`460`/`640`/`480`/`560`/`520`/`580`, `28`, `6`, `20`) moved
    into one `Support/Layout.swift` namespace of named constants (`fieldColumnMaxWidth`, `readableTextMaxWidth`,
    `iconButtonHitSize`, `rowCornerRadius`, `sheetPadding`, and grouped `Layout.ContentSheet`/`FormSheet`/
    `PreviewWindow` sizings). The three content-heavy sheets were **unified** to one size (their per-sheet drift
    was incidental). Pure app-layer refactor, no engine change; the only behavioral delta is the ±20px sheet
    unification (all still resizable). **Completes the UI-audit backlog (F1–F14) — next is the Phase 3
    conclusions UI.**
- **USB/network scanner ingest** (deferred from slice 23) — directly-connected document scanners
  via `ImageCaptureCore` (`ICScannerDevice`); a separate, hardware-dependent lift, only if wanted.
- A full persisted/cross-relaunch undo journal if wanted (slices 20–21's trash are narrow
  recovery carve-outs, not a general journal). (`findDanglingReferences()` + dangling-reference
  surfacing shipped in slice 44e.)


**Exit criteria:** a real user can build and curate an archive end-to-end in the UI
with no CLI.
