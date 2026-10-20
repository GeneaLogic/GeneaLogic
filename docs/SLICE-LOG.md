# GeneaLogic — slice log

The per-slice record of what shipped and, more importantly, **why** — the decisions
that were settled, the invariants each slice established, and the gotchas that cost a
debugging round. This is a *reference*, read on demand; it is not loaded into every
session.

- **Direction and current status** live in [`ROADMAP.md`](ROADMAP.md) — not here.
  When the two disagree, ROADMAP wins. Each slice's full spec is in
  [`slices/`](slices/README.md).
- **Design** lives in [`ARCHITECTURE.md`](ARCHITECTURE.md); the **invariants** live in
  [`../CLAUDE.md`](../CLAUDE.md).
- **The people, towns and addresses are fictional** (since slice 74). Where an entry
  measures "the real archive", the measurement is real; the names in it are stand-ins,
  each carrying the property of the real name it replaced.

Phases 0–3 are done: the engine + index + CLI, the Mac app with its UI-audit backlog
(F1–F14) complete, and the conclusions UI through the 45+ matcher mini-phase, closing
with 46, 46b and 45p; Phase 3.5 (share-readiness) opens with 47, then 51, 52, 54 and 53. At the
last slice: **637 engine tests on macOS** (Linux runs 3 fewer — the ImageIO extractor
suite, compiled out via `#if canImport(ImageIO)`) **+ 139 CLI tests**, both suites run on
Linux via `scripts/linux-test.sh` (Apple's `container`, not Docker), **+ 20 app tests**
(`GeneaLogicAppTests`, new in 52 — the app had no test target before it). CI (macOS +
Linux, plus a `macos-26` job that now *tests* rather than builds the app) gates every
push/PR to `main`; 47 added platform-conditional code for the first time (`Darwin`/`Glibc`
for `flock`), and the counts match as expected.

## Entry format

One entry per slice, **under ~20 lines**: the decision, the invariant it establishes,
and the non-obvious gotcha. It is a record, not a retelling — the diff already shows the
code. If an entry cannot be written that short, that is a sign the slice should have
been two slices.

---

## The log

- **Phase 0** — `GeneaLogicModel` value types + the format spec.
- **Phase 1a** — the `GeneaLogicArchive` engine: create/open, atomic writes via
  POSIX `rename(2)`, the §4.2.1 file-naming invariant, conclusions write path,
  manifest + `verifyIntegrity()`, the §5.1/§6.3 lookup surface, the
  embedded-metadata seam.
- **Phase 1b** — the lookup index is now backed by a persistent
  `.index/index.sqlite` projection (vendored SQLite amalgamation as the `CSQLite`
  C target; `open()` self-heals, `rebuildIndex()` regenerates) behind the
  **unchanged** lookup API; plus the `genea` CLI in a separate top-level
  `GeneaLogicCLI/` package (swift-argument-parser, confined to that package).
- **Phase 2** — `GeneaLogicApp` (Xcode project, SwiftUI
  `WindowGroup` over the engine): open/create + browse a `.genea` (slice 1);
  drag-in / **Add Media** ingest via the new `GeneaLogicExtract` ImageIO
  extractor, surfaced **read-only as embedded-metadata suggestions** — never
  auto-applied (slice 2, the scan-date trap, §6.4); `.genea` registered as a
  **package document type** for Finder open + a package-aware open panel
  (slice 3); **multi-archive windows** — one archive per window via a single
  value-based `WindowGroup(for: URL.self)` + a per-window `ArchiveModel`, value
  dedup, welcome-screen-as-`nil`-value with in-place transform + auto-dismiss of a
  redundant welcome, an `ArchiveAccessStore` bridging security scope across
  `openWindow`'s URL serialization, and `@FocusedValue`-targeted File commands
  (slice 4, ARCHITECTURE.md §7); the **metadata editor** — an explicit Edit/Done
  mode buffering the full record and committing descriptive fields in one
  `updateMetadata` write, plus the **human-confirmed apply step** that promotes an
  embedded-metadata suggestion into an `Event`/`Location` only after the human
  picks the field and corrects the value (scan-date trap, §6.4); descriptive edits
  leave `provenance` untouched, applied assertions ride the artifact's existing
  human/`asserted` provenance (slice 5); **attach-to-existing + file roles** — a
  read-only Files list plus an **Attach File…** menu that adds a file to the
  selected artifact under a chosen `FileRole` via `attachFile`, distinct from the
  new-artifact **Add Media** `+`, both multiplexing the single allowed
  `.fileImporter` via an `ArchiveModel.ImportMode` enum (slice 6); **search** — a
  sidebar `.searchable` filtering the browse list through the engine's index-backed
  `artifacts(matching:)` (free text over title + inline `transcript` + notes, §5.1;
  later widened to `role: .transcript` file text in slice 8 and to the structured
  evidence fields — persons-mentioned names, location text, event type/date/location —
  in the search-coverage fix) (slice 7); the **transcript editor** — a dedicated full-height `TextEditor` sheet
  editing the inline `Artifact.transcript`, committed in one `updateMetadata` write
  (empty → `nil`), plus the **engine work to index `role: .transcript` *file* text**
  so search covers transcripts stored as files: a new `artifact.search_text` index
  column (schema v2 — a version bump that forces existing `.index/` caches to
  rebuild) populated at index time from the file's UTF-8 text, folded into the
  `matches()` haystack — read at index time, never per query (slice 8); **undo/redo
  + detach/replace file** — in-session, per-window `UndoManager`-backed undo for the
  in-place edits (metadata, transcript, apply-suggestion register a record-snapshot
  restore; attach/detach/replace register an engine `revert`). The engine gains
  **reversible file ops**: `detachFile`/`replaceFile` now return a `FileChange` after
  staging the bytes they'd destroy into a temp dir (outside the package), and
  `revert(_:) -> FileChange` applies the inverse — re-adding the **exact** `FileEntry`
  (uid stable) or restoring prior content — returning the opposite change, so undo and
  redo are one ping-ponging call. New per-file **Delete** (confirm) + **Replace…**
  actions in the detail view; the detail pane reloads off a `mutationVersion` so
  undo/redo visibly refresh it (slice 9); **delete artifact** (undoable) — a sidebar
  context-menu "Delete Artifact…" + confirm dialog; the engine's `removeArtifact(_:)`
  now stages the **whole** artifact folder to a temp dir and returns an
  `ArtifactDeletion`, with `restoreArtifact(_:)` copying it back + re-inserting into
  the index/manifest (uid faithful, slug reused when free). Hard-delete + in-session
  undo, **not** a persisted tombstone; conclusions are left untouched (dangling links
  are `verifyIntegrity()`'s job, §2.3) — which is also what keeps the delete cleanly
  reversible (slice 10); the **integrity panel** — File ▸ **Verify Integrity…**
  (`@FocusedValue`-targeted) opens a sheet that runs the engine's existing
  `verifyIntegrity()` from a `.task` (yielding once so the spinner paints before the
  synchronous, main-actor SHA-256 sweep) and shows either an "Archive Is Intact" state
  or the `IntegrityReport.Issue`s grouped **Corruption** (checksum/missing/size — real
  data problems) vs. **Stray Files** (`unreferencedFile` — informational), with
  **Re-run** and a **Rebuild Index** button (`rebuildIndex()`, the safe §5.1
  out-of-band-edit fix; *not* undoable — it regenerates the disposable cache, never a
  record). `repair()` stays unsurfaced (it's a throwing stub); dangling-reference
  detection is deferred to the Phase 3 conclusions UI. Pure app-layer — no engine
  changes. (Gotcha fixed in-flight: a `.sheet` whose content reads
  `@Environment(ArchiveModel.self)` must get the model **injected on the sheet's own
  content** when the `.sheet` modifier sits outside the `.environment(model)` injection,
  or it traps — sheets inherit environment from where the *modifier* is attached, not
  from the presenting view's descendants.) (slice 11); **relaunch persistence** —
  the app now remembers archives across launches via **app-scoped security-scoped
  bookmarks** (new `com.apple.security.files.bookmarks.app-scope` entitlement; an
  explicit `GeneaLogicApp.entitlements` now backs the sandbox config). A new
  `ArchiveBookmarks` (`@Observable`, `UserDefaults`-backed) persists a bookmark +
  recents list; `ArchiveAccessStore.acquire` records a bookmark, and a new
  `ensureAccess(to:)` re-derives a live security scope from one when a window opens
  **without** live access (`ArchiveModel.load()` calls it first, and shows a clear
  "can no longer reach this archive" state if it fails — moved/deleted; the dead
  bookmark self-prunes). Two surfaces: **File ▸ Open Recent** (live via the observable
  store; reopen resolves the bookmark, Clear Menu keeps bookmarks) and **window
  restore across relaunch** — handed to the **OS** (`restorationBehavior(.automatic)`),
  which correctly honors the user's "Close windows when quitting an app" setting; a
  restored bare-`URL` window-value carries no live scope, so each restored window
  re-derives one from its bookmark in `load()`. **macOS-14+ gotcha that cost a
  detour:** SwiftUI window restoration is silently disabled unless an
  `NSApplicationDelegate` (`@NSApplicationDelegateAdaptor`) returns `true` from
  `applicationSupportsSecureRestorableState` — without it, no state is saved and
  nothing restores (don't mistake that for the system setting suppressing it; also
  note a **sandboxed** app's saved state lives in its *container*, not
  `~/Library/Saved Application State/`). Respecting the OS setting (vs. an app-managed
  always-restore) was a deliberate call (slice 12); the **tag-filter UI** — a toolbar
  **Filter** menu (`TagFilterMenu`) listing every tag in the open archive as a `Toggle`
  with its artifact count (derived from the loaded `ArtifactSummary.tags` — no extra
  query), selected tags driving the **structured** `ArtifactQuery.tags` facet (exact,
  whole-tag, AND-combined) *alongside* the §5.1 free-text search in **one**
  `ArtifactQuery` — so text and tags AND together. `ArchiveModel` gained `selectedTags`,
  `tagFacets`, a unified `applyFilters()` (replacing `search()`), `isFiltering`, and
  `toggleTag`/`clearTagFilter`; `displayedArtifacts` falls back to the full list when no
  filter is active, and `refresh()` prunes any selected tag that no longer exists so the
  filter can't stick on a vanished tag. The menu's label is title+icon (the count is
  otherwise lost — a toolbar menu collapses to icon-only): "Filter" → "Filter (N)" with a
  filled icon while active; the menu is **disabled** when the archive has no tags. Pure
  app-layer — the engine's `query.tags` already did exact AND filtering, kept separate
  from free text exactly for this; the menu view is injected `.environment(model)`
  explicitly (toolbar content is hoisted out of the body, same caution as the sheets)
  (slice 13); **Add Media on the undo stack** — `ingest` (new-artifact ingest, the `+` /
  drag-in path) is now undoable, completing the in-session undo story (it was the last
  unreversible mutation). Adding an artifact is the inverse of deleting one, so this
  **reuses the reversible-delete machinery**: each created artifact registers a
  "delete me" undo (`registerArtifactRedelete`, now `actionName`-parameterized and shared
  with `deleteArtifact`'s restore side), so the first ⌘Z removes it via the engine's
  `removeArtifact`→`ArtifactDeletion` (folder staged outside the package) and ⌘⇧Z restores
  it uid-faithfully via `restoreArtifact`. A multi-file Add Media (or multi-file drag)
  registers one redelete **per** new artifact, but the whole batch runs in one run-loop
  event so the window's `UndoManager` **event-groups** them — one ⌘Z reverts every
  artifact the call added, one ⌘⇧Z brings them all back (the same grouping the multi-file
  Attach path already relies on). Pure app-layer, no engine change (slice 14); **file
  preview & export** — the detail pane's Files list is now selectable
  (each row is a full-row `.plain` `Button` — *not* an `onTapGesture`, and `textSelection`
  is omitted since it would swallow the click — with a leading icon, a hover + selection
  highlight, and a "Select a file to preview" hint, so it's clearly clickable);
  selecting a row opens a **preview pane beside the metadata** in an `HSplitView` (the
  split's native divider resizes it — no hand-rolled drag handle), with a header carrying
  pop-out + close (28pt hit areas). Preview rendering is **type-dispatched and fully
  in-process** (`FilePreviewContent`: `Image` for images, `PDFView` for PDFs, an
  `NSAttributedString`-backed read-only `NSTextView` for word-processing docs, and a
  placeholder otherwise) — **no `QLPreviewView` at all** (removed in the slow `.docx` preview fix, see
  below). A **pop-out** button opens the file in its own window (a
  value-based `WindowGroup(for: FilePreviewRequest.self)`, restoration disabled). The per-file
  ⋯ menu gains **Quick Look**, **Open in Default App**, **Save a Copy…** (`NSSavePanel`), and
  **Open in Separate Window**. The inline preview reads the package file directly via a new
  read-only engine accessor **`fileURL(of:in:)`** (the app holds the archive's security scope,
  so an in-process view can render it); anything that leaves the app — pop-out, Open in Default
  App — hands over a **session-temp copy** (`ArchiveModel.temporaryCopy`), and Save a Copy
  writes a copy to the chosen location (`exportFile`), so the **package original is never
  exposed** (an external app mutating it would desync the manifest/index). The one engine
  change is that accessor (+1 test → 116/113); the rest is app-layer (slice 15);
  **detail-view field coverage + manual event/place entry** — the detail
  view now mirrors *all* descriptive fields and stops leading with internal IDs:
  read-only mode shows **Language / Original Format / Notes when filled** (read off
  the full record loaded in the same `.task` as files/transcript, not just the browse
  summary), **UID/Slug** moved to a de-emphasized **Identifiers** group at the bottom,
  and **Primary Date** is shown *only when present* with an "earliest event date"
  caption — it stays **read-only because it's derived** (the earliest of the events'
  dates, §2.3), never a free-text field. The deeper fix is a new **Events & Places**
  section that finally makes `events`/`locations` **visible** and **addable without a
  suggestion**: the old `ApplySuggestionSheet` is generalized to `AssertionEditorSheet`
  with a `Prefill` enum (`.suggestion(entry)` keeps the §6.4 scan-date-trap path —
  captured-value row, event/place picker, corrected value — while `.blankEvent` /
  `.blankPlace` start empty for manual entry), so a date that isn't in the file's
  metadata can now be recorded as an `Event`. Both add paths and a per-row trash
  **remove** write through `updateMetadata`, so every change is **undoable** (⌘Z) and
  index-addressed (delete is by array index against the loaded snapshot, bounds-checked
  inside the mutation). Pure app-layer, no engine change (slice 16); **on-demand
  metadata re-scan** — a per-file **⋯ ▸ Scan for Metadata** re-runs the
  `GeneaLogicExtract` extractor against the **already-stored** file (read via slice 15's
  `fileURL(of:in:)`, in-process, no temp copy) and drops any embedded metadata into the
  session `capturedMetadata` cache, so the read-only **Embedded Metadata (Suggestions)**
  section + its **Apply…** (the slice-16 `AssertionEditorSheet.suggestion` path) work for
  files added in a **prior** session, not just this one. Nothing is persisted or
  auto-applied — re-scan only repopulates the in-memory cache (§6.4 scan-date trap
  unchanged); a file with no extractable metadata reports via a **benign `actionInfo`
  alert** (a new info channel distinct from `actionError`, so "nothing found" doesn't read
  as a failure). Pure app-layer (reuses the `fileURL` accessor + the `MetadataExtractor`
  protocol), no engine change (slice 17); **restore selected artifact on relaunch**
  — the per-window artifact selection, previously in-memory `@State`, is now
  `@SceneStorage("selectedArtifactID")`, so it rides the **same** state-restoration
  machinery as the window (slice 12) and comes back when a window restores. Stored as the
  id's raw string (`@SceneStorage` holds only scalars) and bridged to an `ArtifactID?`
  binding; per-scene, so each archive window restores its **own** selection, and a stored id
  whose artifact was deleted between sessions falls back to the placeholder (it's resolved
  against `model.artifacts` only at render). Deliberately scoped to *selection only* — search
  text / tag filters / preview-file *can* ride the same pattern but were deferred (reopening
  into a filtered list risks a "where did my artifacts go?" surprise; edit mode, open sheets,
  and §6.4 suggestions should never restore). Pure app-layer (slice 18); **persons-mentioned
  editing** — a new **Persons Mentioned** section in the detail view makes
  `Artifact.personsMentioned` visible and editable (the companion to slice 16's Events &
  Places, and the first **evidence-layer** input Phase 3's relationship inference will read).
  Each `PersonMention` is recorded *as it appears in the document*: name as recorded, role
  (subject/informant/witness/parent/spouse), information quality (primary/secondary/
  undetermined), and an optional "age as recorded" (`attributes["ageAsRecorded"]`). The
  `AssertionEditorSheet` (née apply-suggestion sheet) gains a `.blankPerson` prefill beside
  `.blankEvent`/`.blankPlace` (the suggestion path still routes only to event/place — EXIF
  never suggests a person); the record-local `localRef` is **auto-minted** at write time (the
  lowest unused `p<n>`, computed against the *current* record inside the `updateMetadata`
  closure), never user-entered, so a future `EvidenceLink` has a stable anchor. Add and a
  per-row trash both write through `updateMetadata`, so both are **undoable** (⌘Z); a removed
  `localRef` may leave a dangling link for `verifyIntegrity()` (§2.3) — conclusions untouched.
  Strictly evidence-layer: a `PersonMention` is "the name as it appears here," **never a tree
  identity** — resolving a mention to a concluded `Person` and asserting relationships are
  Phase 3 (conclusions UI). The detail subtitle hides quality when undetermined and shows age
  only when present. Pure app-layer (the model has carried `personsMentioned` since Phase 0),
  no engine change (slice 19); **persisted trash for deleted artifacts** — deleting an
  artifact now moves its folder into a reserved in-package **`.trash/<uid>/`** (payload +
  a `deletion.json` sidecar) *before* the index/manifest forget it, so a delete survives
  quit and is recoverable across sessions — not just by in-session ⌘Z. A new **File ▸ Show
  Trash…** sheet lists trashed artifacts (title + deleted-when) with **Restore**, per-row
  **Delete Permanently**, and **Empty Trash** (both irreversible). Engine: `removeArtifact`
  stashes into the trash (atomic rename within the package) instead of a temp dir, and
  `restoreArtifact` (the ⌘Z path) is now a thin alias over the new `restoreFromTrash(_:)` —
  **⌘Z and the Trash UI are two views on the *same* store**, so undoing a delete also
  consumes its trash entry. Plus `trashedArtifacts()`, `deleteFromTrash(_:)`, `emptyTrash()`.
  The new filesystem mechanics live in a **kind-agnostic `TrashStore`**, and `deletion.json`
  (the `TrashEntry` model record) carries a **`kind` discriminator** (`.artifact` today),
  so extending the trash to detached *files* later needs no format migration — only a `.file`
  case + a re-attach restore path. `.trash/` is a top-level **reserved** sibling of
  `artifacts/` (joining `.index/`), so it's automatically invisible to the manifest, the
  index rebuild, and `verifyIntegrity()` — `rebuildIndex()` can't resurrect a trashed
  artifact (regression-tested). Conclusions stay untouched (§2.3). Engine change → Linux-
  verified; 124/121 engine + 6 CLI. **Undo coherence:** Trash-sheet **Restore is itself
  undoable** (⌘Z re-deletes it), so the in-session undo stack and the sheet stay two doors
  to one store rather than fighting; and an undo/redo step whose bytes were **permanently**
  removed (Empty Trash / Delete Permanently) **no-ops gracefully** — a benign titled notice
  via the shared `showInfo(_:title:)` info channel (not an error), with the stack advancing
  so further undo still works. (NSUndoManager can't relabel a buried menu item after the
  fact, so the stale item keeps its name until invoked — the notice is the honest close.)
  (slice 20); **detached-file trash** — the per-file **Delete** (detail-pane ⋯ ▸ Delete) is
  now trash-backed too: `detachFile` **moves the file's bytes into `.trash/<FIL-uid>/`**
  (keyed by the file's own uid; `FIL-`/`ART-` can't collide in the trash namespace) instead
  of the old temp-staging, so a deleted file survives quit and is recoverable across sessions
  — the file analog of slice 20. Reuses the **same `.trash/` store** via the `TrashEntry.kind`
  discriminator (now a live `.file` case beside `.artifact`; new `FileTrashInfo` carries the
  full `FileEntry` + owning `artifactUID`/title) — *the forward-design from slice 20, cashed in
  with no format migration*. Engine: `detachFile`→trash (record-only entry when the bytes were
  already gone), new `restoreFile(_:)` (re-attaches to the owning artifact, reuses the original
  path when free, throws `fileTrashEntryNotFound`/`artifactNotFound`), `trashedFiles()`,
  `deleteFileFromTrash(_:)`; `emptyTrash()` already clears both kinds. `FileChange.removed`
  dropped its temp `stagedBytes` (bytes live in trash, found by uid); `revert` of `.removed`
  now restores from trash, so **⌘Z and the Trash UI are two doors to one store** exactly like
  artifacts — *replace's* prior content stays in-session temp (deliberately **not** trashed:
  swapping content isn't deleting a file). App: ArchiveModel `restoreFile`/`trashedFiles`/
  `deleteFileFromTrash`; the **TrashSheet** gained an **Artifacts** + **Files** two-section
  layout (shared Empty Trash); **Restore is undoable** (⌘Z re-detaches) and a stale undo/redo
  whose bytes were permanently removed **no-ops gracefully** via the same `showInfo(_:title:)`
  channel ("Can't Restore File"). Engine change → Linux-verified; 133/130 engine + 6 CLI.
  Conclusions untouched (§2.3); a removed file's `localRef`/`EvidenceLink` may dangle for
  `verifyIntegrity()` (slice 21); **vendored-SQLite hygiene** — the in-tree amalgamation
  (`Sources/CSQLite`, the `.index/` driver) was a stale incidental pin (3.46.1, ~22 months
  old at vendoring; the spike chose to *vendor*, never that specific version) and is now
  bumped to **3.53.3**. New **`scripts/update-sqlite.sh`** fetches the latest amalgamation and
  **verifies its SHA3-256 against sqlite.org's published product data** before the bytes touch
  the repo (supply-chain integrity), swaps `sqlite3.c`/`sqlite3.h`, and rewrites the README
  version/URL; a monthly **`sqlite-freshness`** GitHub workflow compares the pinned version to
  upstream and opens a dedup'd tracking issue when behind (Dependabot can't track a vendored C
  file). Practical exposure was always low — the engine only opens its own **rebuildable**
  `.index/index.sqlite`, never untrusted DB files, and all SQL is bound-parameter (`SQLITE_DQS=0`),
  so no untrusted text becomes SQL — but staying current is cheap hygiene. No schema/migration
  (the index is rebuildable); macOS + Linux + app all green on 3.53.3 (133/130 engine + 6 CLI,
  unchanged) (slice 22). **Bug fixes since:** **search coverage** — free-text search now also covers the
  structured evidence fields (persons-mentioned names, location text, event type/date/location),
  folded into the `matches()` haystack with no index change (they're already in the decoded
  artifact); **slow `.docx` preview** — a `.docx` preview took ~30s. Root-caused: Quick Look's generator is fast
  (~70ms) but **`QLPreviewView` can't render Office docs in this sandbox** (live preview stalls
  ~30s; `QLThumbnailGenerator` errors outright) — `qlmanage` proves it's the sandbox, not the
  generator. Fix: drop `QLPreviewView` entirely and render word-processing docs **in-process** via
  `NSAttributedString(url:)` → read-only `NSTextView` (the app reads the package file directly;
  AppKit parses docx/doc/rtf/odt/txt), so the docx shows its **actual text instantly**; images/PDFs
  stay in-process; other types get a placeholder pointing to Open-in-Default-App. App-only; verified
  live (docx text + jpg both instant).
- **Phase 2 (cont.)** — **Continuity Camera scan ingest** — scan a document with a
  nearby iPhone/iPad and drop it straight into the archive, for **both** a new artifact (the
  toolbar `+` pops **one connected AppKit menu**: *Add Media…* above the Continuity *Take Photo* /
  *Scan Documents*) and an existing one (the detail **Attach File…** menu gains a *Scan with iPhone
  or iPad…* submenu, per `FileRole` — role chosen first, then the scan options pop). macOS delivers
  Continuity Camera through the **NSServices responder chain**, not a callable picker: a zero-size
  `ContinuityCameraReceiver` (`NSView` + `NSServicesMenuRequestor`) hosted in the window returns
  itself from `validRequestor(forSendType:returnType:)` for image/PDF return types, so AppKit
  auto-inserts the scan items into the menu we show after `makeFirstResponder`. **Three hard-won
  AppKit facts (each cost a debugging round):** (1) present via **`NSMenu.popUpContextMenu(_:with:for:)`**
  — AppKit inserts the Continuity items only through the *contextual-menu* path; a bare
  `menu.popUp(positioning:at:in:)` pops an **empty** menu (responder correct, items never inserted);
  (2) **defer to the next runloop turn** (the trigger is a SwiftUI menu/button action, so a menu may
  still be dismissing — you can't open a new menu session while one tracks); (3) AppKit **always
  inserts the items *flat*** into whatever menu is shown (whenever the requestor is anywhere in the
  responder chain) — there is **no public way to nest them under an "Import from iPhone ▸" submenu**
  the way Finder does (verified: pre-creating a parent+empty-submenu just duplicates; gating the
  requestor to a submenu's `menuNeedsUpdate` suppresses the flat items but populates nothing). So the
  UI is one flat-but-connected menu, not Finder's grouped submenu. The capture arrives in
  `readSelection(from:)` as a **multi-page PDF** (scan) or image (photo → normalized to PNG); the
  bytes are written to a session-temp file and funneled through the **existing** `ingest`/`attach`
  paths, so a scan is metadata-extracted and **undoable** (⌘Z) exactly like Add Media / Attach, and
  the temp file is removed once the engine has copied it in. `ArchiveModel` stays AppKit-free — it
  reaches the scanner through a UI-free `ContinuityScanning` protocol (`beginAddOrScan` /
  `beginScanAttach(to:role:)`); the `+`'s *Add Media…* item is an AppKit `NSMenuItem` whose
  target/action calls back into the model. Pure app-layer, **no engine change, no new entitlement**
  (the camera is the iPhone's; receiving needs none). **Testability caveat:** the menu wiring +
  no-device no-op are verified live, but the actual iPhone→Mac handshake can't be driven by
  automation — it's a human live-device test (slice 23).
- **Phase 2 (cont.) — UI refinement** — a read-only **UI audit** ([`docs/UI-AUDIT.md`](UI-AUDIT.md))
  triaged the app's surfaces into a prioritized backlog (F1–F14, tagged HIG / SwiftUI-idiom / UX)
  before the Phase 3 transition; we're working it slice by slice. **F2, Slice A — document-primary
  layout + metadata inspector** (slice 24): the artifact detail view was flipped from a
  metadata-first scrolling stack to **document-first**. The detail pane now shows the artifact's
  **document** (primary-file preview via the existing in-process `FilePreviewContent` over
  `fileURL(of:in:)`), with a **horizontal file-selector strip** for multi-file artifacts
  (auto-selecting the primary = first `preservationMaster`, else first file) and a **No Files Yet**
  empty state (with an Attach File… menu) for metadata-only artifacts. All metadata — the
  descriptive fields, Events & Places, Persons Mentioned, Transcript, Files management, embedded-
  metadata suggestions, Identifiers — moved into a **toggleable trailing `.inspector()`** (toolbar
  `info.circle` toggle — the circled "i" à la Preview, deliberately **not** a trailing-panel
  glyph, which would mirror the leading sidebar toggle; visibility persisted per-window via
  `@SceneStorage("inspectorShown")`,
  default shown). The **Edit/Done** buffered-commit mode is **preserved**, now *inside* the inspector
  so the document stays visible while you transcribe evidence off it (the whole point). The artifact
  **title** is the document pane's header (the inspector is too narrow for the old `.largeTitle`);
  file selection **syncs both ways** between the strip and the inspector's Files list.
  **Gotcha fixed in-flight:** `.onChange(of: artifact.uid)` must **not** also nil `selectedFileID`
  — it races the `.task` that re-derives the primary file (the task's own validity guard already
  drops a selection belonging to the previous artifact), or the document pane lands on "Select a
  File" after every artifact switch. Pure app-layer, **no engine change**; the old `HSplitView`-
  on-file-click preview pane (`FilePreviewPane`) is gone. **Slice B (= audit F3, pending):** convert
  the inspector to always-editable commit-on-blur fields, retiring Edit/Done (slice 24).
  **F3 — Slice B: always-editable inspector** (slice 26): the Edit/Done mode is **gone**. The
  inspector's **Details** section (new `EditableArtifactFields`) shows the descriptive fields
  (title, media type, source tier, tags, language, original format, notes) as live controls;
  text fields **commit on blur** (focus moving to another field) or on **Return**, the two
  pickers commit on change. Each commit is its own undoable `updateMetadata` write, fired only
  when the value changed; the required **Title** reverts to stored if blurred empty; the derived
  **Primary Date** stays read-only (passed in from the summary — it's not on the `Artifact`).
  Local `@State` buffers in-progress text and re-seeds from the loaded record via
  `onChange(of: artifact)` (so undo/redo or an applied suggestion never leaves a stale field).
  Undo is now **per field** (not one "Edit Metadata" batch) — a deliberate shift. **macOS
  gotcha:** clicking empty whitespace does **not** resign a `TextField`'s first responder, so a
  commit lands on focus moving to another control or on Return, never on a stray click — don't
  expect blur-on-empty-click. Pure app-layer; removed `ArtifactEditFields`/`ArtifactEditorForm`/
  the read-only `ArtifactDetailFields`.
  **F1 — sidebar rows show metadata, not the UID** (slice 25): the browse-list row subtitle was
  the raw `ART-…` UID — developer addressing, the single most impactful "not Mac-like" wart and a
  contradiction of the detail view's own "UID isn't researcher-facing" stance. It's now
  `primary date (when present) · source tier · media type` (blanks omitted; `ArtifactRow` takes
  the whole `ArtifactSummary`), so a dateless artifact reads e.g. "compiled · image". Trivial
  app-only change; facets are easy to retune.
  **F5 — resizable sheets** (slice 27): all four sheets (Assertion editor, Transcript editor,
  Integrity report, Trash) were fixed-size (`.frame(width:height:)`) and so non-resizable. The fix
  is **`.presentationSizing(.fitted)`** plus a `min`/`ideal`/`max` frame on each sheet's content.
  **The gotcha that cost a detour:** macOS 15 (Sequoia) made SwiftUI sheets **fixed-size by
  default** — a flexible content frame alone changes only the *opening* size and adds **no
  drag-resize handle** (verified live: three drag attempts on the transcript sheet did nothing).
  `.fitted` is the documented opt-back-in to resizable sheets ([Apple DTS, forum
  758456](https://developer.apple.com/forums/thread/758456)); it must be paired with a framed
  min/max for the drag range. No AppKit needed (the `NSWindow` style-mask hack was the fallback we
  didn't take). The transcript editor's inner `TextEditor` also dropped its fixed `480×320` floor
  for `maxWidth/maxHeight: .infinity` so it fills the now-growable sheet. The three content-heavy
  sheets use `maxWidth/maxHeight: .infinity` (grow to screen); the Assertion *form* resizes in
  width only (`maxWidth: 640`), its height fitting the fields. Pure app-layer, no engine change.
  **F7 + F14 — sidebar list-controls cluster + sort** (slice 28): the tag filter lived in the
  *trailing* toolbar, across the window from the sidebar search field it AND-combines with (F14). It
  now sits in a **`ListControlsBar`** pinned under the search field via `.safeAreaInset(edge: .top)`
  — **Filter** (the relocated `TagFilterMenu`, unchanged) on the left, a new **Sort** menu on the
  right, `.bar` material + a divider. The trailing toolbar keeps only the **`+` Add** button (the
  audit's "reserve the trailing toolbar for object/view actions"). The bar is hidden when the archive
  has **zero** artifacts (empty-state stands alone) but stays visible when a *filter* yields nothing
  (so you can clear it). New **sort** (F7, the `SortMenu`): client-side over the loaded summaries —
  `ArchiveModel.sortKey` (`.title`/`.dateAdded`/`.primaryDate`) + `sortAscending`, applied as a final
  `sorted(_:)` pass in `displayedArtifacts` (over the full *or* filtered list). **Date Added** sorts by
  `uid.raw` (the UID is a **time-ordered UUIDv7**, so its raw string sorts by creation time — no
  timestamp field needed); **Primary Date** sorts the ISO string with **undated artifacts always last
  in both directions**; a title→uid tiebreak keeps the order stable. Direction labels are phrased per
  key ("A to Z", "Newest First", "Earliest First"). Sort state is **in-memory** (not restored across
  relaunch — same deliberate scoping as search/filter, slice 18); default `.title` ascending
  reproduces the engine's existing order, so nothing looks different until the user picks a sort. The
  `ListControlsBar`/`SortMenu` are inline body content, so they inherit the environment model (no
  explicit injection, unlike the hoisted toolbar). Pure app-layer, no engine change.
  **Bug fix — new artifact ends up selected** (slice 29): creating an artifact (Add Media `+`,
  drag-in, or Continuity scan-new) previously left the selection untouched — you'd add a file and stare
  at "Select an Artifact" until you clicked the new row. `ArchiveModel.ingest` now tracks the last
  artifact it minted and publishes a one-shot **`lastCreatedArtifact: ArtifactID?`** intent after its
  `bumpAndRefresh()` (set only when a create actually succeeded; a multi-file Add Media lands on the
  last one). The container observes it via `.onChange`, moves the **scene-stored** `selection` there,
  and clears the intent — kept as an *intent* rather than a direct write because selection lives in
  `@SceneStorage` in the view, which the model must not touch. `attach` (adds a file to an *existing*
  artifact) deliberately doesn't set it. Undo degrades cleanly: ⌘Z removes the just-added artifact and
  the detail pane falls back to the placeholder (selection resolves against `model.artifacts` at
  render). Pure app-layer, no engine change.
  **Bug fix — zoomable non-PDF previews** (slice 30): image previews were a static
  `Image().resizable().scaledToFit()` with no way to zoom, while PDFs got `PDFView`'s magnification
  for free. `FilePreviewContent`'s image branch now renders through a new **`ZoomableImageView`**
  (`NSViewRepresentable` over `NSScrollView` with **`allowsMagnification = true`**) — the *same
  native magnification mechanism `PDFView` is built on*, so images reach zoom parity: pinch/trackpad-
  magnify to zoom (1×–16×), scroll to pan. **`magnification == 1` maps to fit-to-window** — an
  `NSImageView` autoresized (`[.width, .height]`) to fill the clip view with
  `.scaleProportionallyUpOrDown` (matching the old `scaledToFit` look), so a window resize refits
  automatically while preserving the user's zoom factor; zoom-out is clamped at fit (`minMagnification
  = 1`). The `ImagePreview` shell (off-main load + progress/failed states) is unchanged; only the
  render swaps. The pop-out `FilePreviewWindow` reuses `FilePreviewContent`, so it gains zoom too.
  **Verification caveat:** everything around the gesture is automatable and was live-verified (renders
  fit, refits proportionally on resize, no regression) but the **pinch/magnify gesture itself can't be
  synthesized by computer-use** (no pinch action; `NSScrollView` magnification has no default
  keyboard/mouse trigger) — the human confirmed pinch-zoom + pan live. Pure app-layer, no engine
  change.
  **Bug fix — duplicate window on relaunch** (slice 31): double-clicking a `.genea` that was
  restored on launch spawned a **second** window for it. **Two** root causes, found by isolating the
  running-open path from the relaunch path. (1) `WindowGroup(for: URL.self)` dedups by URL **equality**,
  but a `.genea` is a **package (directory)**: Finder's `onOpenURL` delivers a **trailing-slash** URL
  (`…/x.genea/`) that is **not** `==` to the slash-less value a restored window carries — and
  `standardizedFileURL` does **not** reconcile them (verified empirically). New **`URL.canonicalArchiveURL`**
  (`URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true)`) normalizes the trailing slash;
  applied at **every** point a URL becomes a window value (`onOpenURL`, Open Recent, New/Open panels, the
  Welcome open/create binding) and as the `ArchiveAccessStore` key. `.path` is unchanged by it, so
  `ArchiveBookmarks` (which keys by `.path`) is untouched. **Gotcha (caught in code review):**
  `canonicalArchiveURL` rebuilds the URL from a path via `URL(fileURLWithPath:)`, which **drops the
  security scope** — so it must be applied **only to the window value**, never to the URL handed to
  `acquire`/`Archive.create` (those need the *original* scoped picker/Finder URL to
  `startAccessingSecurityScopedResource()` and mint the bookmark; `acquire` derives the canonical dedup
  key internally). Canonicalizing before `acquire` silently breaks first-time access + bookmark creation
  for a never-opened archive (masked in testing by pre-existing bookmarks). This alone fixes the
  **running**-open dedup (live-verified: opening an already-open archive now focuses its window). (2) The reported relaunch dup is
  a **race** the URL fix can't touch: on relaunch the OS restores the archive's window **and** `onOpenURL`
  calls `openWindow`, and if the restored window isn't in the scene table yet, a second is created — no
  `WindowGroup`-level API (`handlesExternalEvents` included — it's documented to route custom URL schemes,
  not dedup value windows nor coordinate with restoration) closes this gap; only the document architecture
  (`NSDocumentController`/`DocumentGroup`) does — it processes a document open *after* restoration and
  focuses the already-open document — but the package/engine design rules `DocumentGroup` out. **So we
  replicate that ordering:** a new **`ArchiveOpenCoordinator`** buffers the `onOpenURL` `openWindow` until
  **`applicationDidFinishLaunching`** (which AppKit posts *after* it restores windows) plus one runloop hop
  for SwiftUI to register the restored scenes. By then the restored window is in the scene table, so a
  single `openWindow(value: canonicalURL)` **de-dups onto it and brings it to the front** — no second
  window, no flash, and (unlike an earlier eviction-based cut) it fixes **focus**: double-clicking a
  *background* archive on relaunch now raises that archive's window (it doesn't just survive, it comes
  forward). Because the deferred open always runs *after* restoration, the restored window is always the
  *first* to register — so a slim **first-wins** `ArchiveAccessStore` registry (`claimWindow`/`resignWindow`,
  canonical URL → `UUID` token; each window claims its slot in `.task` before `load()`, a would-be duplicate
  dismisses itself) is a sufficient **safety net** with no priority/eviction logic. (This *replaced* a more
  complex restored-wins/eviction/`@SceneStorage("windowWasRestored")` design — the deferral made the race,
  and thus all that machinery, unnecessary.) Access release is **owner-gated** (`resignWindow` returns
  whether this window owned the slot) so a dismissed duplicate can't revoke the survivor's security scope.
  **Live-verified:** two-archive background-double-click raises the right window (single window, correct
  front); single-archive relaunch keeps its selection; first-time open of a never-bookmarked archive gains
  access + a bookmark and restores next launch. Pure app-layer, no engine change.
  **Bug fix — consistent file-role control** (slice 32): file-role assignment was inconsistent and
  one-way — a **new** artifact's first file was hard-assigned `.preservationMaster` with no way to change it,
  while **attach-to-existing** made you *pre-pick* a role before the file existed (and the Continuity scan
  path pre-picked a role in a SwiftUI submenu that then popped a *second*, disconnected AppKit menu for the
  actual scan) — and once wrong, a role couldn't be corrected at all (`grep` confirmed **no** role-mutation
  call existed in the engine). Fix, per the issue's own steer: **one sensible default everywhere + change it
  later.** New engine **`setFileRole(_:in:to:) -> FileRole`** (the triage pass's only engine change) — a
  metadata-only edit of `FileEntry.role` (content/uid/path untouched) that **returns the prior role** so the
  app's UndoManager reverses it with a second call; a no-op change (same role) skips the write; throws
  `artifactNotFound`/`fileNotFound`. App: **all** newly added files (ingest *and* attach) now default to
  `ArchiveModel.defaultFileRole = .preservationMaster` (one named constant), so the attach pre-pick is gone —
  `ImportMode.attach` **dropped its `role:` parameter**. The role is corrected afterward via a new per-file
  **⋯ ▸ Role** submenu (a `Picker` over the four roles, checkmark on the current), routed through an undoable
  `ArchiveModel.setFileRole` (`actionName: "Change File Role"`, symmetric undo/redo ping-pong; degrades
  **gracefully** to a benign notice if the file went out-of-band). The empty-state's first-attach affordance
  became a plain **Attach File…** button (was a role submenu). **Continuity-menu disconnect (also fixed here):**
  removing the role pre-pick did **not** by itself fix the two-menu disconnect on attach — that was structural,
  *not* about roles: the `+` was a plain `Button` popping **one** connected AppKit menu (`requestAddOrScan`),
  while attach was a **SwiftUI `Menu`** whose *Scan…* item then popped a **second** AppKit menu. Fixed by
  routing the attach paperclip through the **same** `requestAddOrScan` path as the `+` (new
  `ArchiveModel.beginAttachOrScan(to:)`; `requestAddOrScan`/`presentAddMenu` gained a `leadingTitle` param —
  *Add Media…* vs *Attach File…*; the old `beginScanAttach`/`requestScan` scan-only path retired). Both are now
  one connected menu. **Live surprise (contradicts the slice-23 "always flat" note):** with a leading item
  present, macOS **nests** the Continuity items under an *Import from iPhone or iPad ▸* submenu grouped by
  device (Finder-style), not flat — verified live with real devices. Overlaps UI-audit **F8** (the
  role-control half). Engine change → Linux-verified (135/132 engine + 6 CLI); role default + change + undo/redo
  + connected scan menu all live-verified.
  **F4 — recent archives on the welcome screen** (slice 33): `WelcomeView` was an icon + two buttons; the
  archives the user has opened were reachable only through File ▸ Open Recent. It now shows a **Recent**
  section below the Open/New buttons — one row per bookmarked archive (archivebox icon + name over its
  tilde-abbreviated containing folder, hover highlight), **height-capped at 5 rows** and scrollable beyond,
  **hidden entirely** when there are no recents. It reads the `@Observable` `ArchiveBookmarks.shared`
  (`recents`/`recentURLs()`) so the list updates live as archives are opened or removed. Clicking a row
  **transforms this welcome window in place** into the archive — the *same* `url`-binding write the Open/New
  buttons use (Xcode/Pages "start window" behavior), after `ArchiveAccessStore.ensureAccess` re-derives the
  sandbox scope from the persisted bookmark; an already-open archive is de-duped by the slice-31 `claimWindow`
  net, and a moved/deleted one shows `ArchiveModel`'s existing **"Couldn't Open Archive"** state while the dead
  bookmark **self-prunes** on the next launch (both verified live). **Reopening a recent bumps it to the top**
  of the list (TextEdit-style) — from the welcome list *and* File ▸ Open Recent. Both reopen via `ensureAccess`
  (which, unlike `acquire`/`remember`, never records a bookmark and so never reordered recents), so the
  reopen policy is centralized in one helper — **`ArchiveAccessStore.reopenRecent(_:) -> URL`** (canonicalize →
  `ensureAccess` → **bump on success only** via the new bookmark-free `ArchiveBookmarks.promote`, the
  front-insert factored out of `remember` into a shared `moveToFront`) — leaving each call site just its
  window tail (`url = …` transform vs `openWindow(value: …)`). A failed reopen isn't promoted (it's being
  pruned). *(The single-helper factoring came out of the slice's own /code-review.)*
  A per-row context menu adds **Show in Finder** (`NSWorkspace.activateFileViewerSelecting`) and **Remove from
  Recents** (`ArchiveBookmarks.forget`, live-updating the list). **Sandbox gotcha (caught live):** `NSString.abbreviatingWithTildeInPath` keys off
  `NSHomeDirectory()`, which in a sandboxed app is the *container* path — so it never abbreviates a real
  `/Users/<name>` path (showed `/Users/<name>/Public`, not `~/Public`); resolve the true home via
  `getpwuid(getuid()).pw_dir` instead. Pure app-layer, **no engine change** (135/132 engine + 6 CLI unchanged).
  Deferred (a distinct mechanism, not needed for the recents win): drag-a-`.genea`-onto-the-welcome-window.
  Overlaps UI-audit **F4**.
  **F8-remainder — consistent section affordances + unified hover-row chrome** (slice 34): the detail-view
  section-header "add" controls were three different looks — Events & Places a bright borderless `Menu`
  (`.borderlessButton`), Persons Mentioned a *bordered push button*, Files a dim borderless button — and (found
  only by looking live, not from the code) **Transcript** was *also* a bordered push button, a fourth-section
  variant the audit hadn't named. All four are now **one bright, leading-icon family** built from a shared
  **`AddAffordanceLabel`** (icon + title, plus a trailing chevron when the control **opens a menu**). The
  key lesson, learned over three brightness iterations (all app-visible, none predicted by the mockup or the
  code): **don't layer `.foregroundStyle` on top of a button/menu style that imposes its *own* foreground** —
  `.borderless`/`.borderlessButton` each render the label *muted* (which read as **disabled**) and
  `.foregroundStyle(.primary)` doesn't reliably override them, while `.menuStyle(.button)` renders bright, so
  mixing them made the affordances mismatch either way. The fix is to use the one style that imposes **no**
  color — **`.buttonStyle(.plain)`** on all four (the Events `Menu` via **`.menuStyle(.button)` +
  `.buttonStyle(.plain)`**) — so the shared label's `.foregroundStyle(.primary)` is the **single source** of
  their appearance and all four render identically. `.plain` also renders the label *faithfully* (unlike
  `.borderlessButton`, which drops custom trailing content), so `AddAffordanceLabel`'s own chevron shows on
  both menu-poppers — no reliance on a native menu indicator. **Chevron semantics:** the chevron marks the two
  affordances that **pop a menu** (Events "Add…", and Files "Attach File…", which always pops the connected
  Attach / Import-from-iPhone menu) vs. the two **direct-action** buttons that open a sheet immediately (Add
  Person…, Add/Edit Transcript…) — a Files chevron was the user's own ask, and it honestly signals "reveals
  more." The Embedded-Metadata **Apply…** stays a `.link` (a per-*row* action inside the suggestions grid, a different
  control class from the section-*add* controls — deliberately **not** folded in). The hand-rolled row chrome —
  6/8 padding + a rounded hover (and, for files, selection) fill, previously copy-pasted in `AssertionRow`,
  `FileRow`, and (slice 33's deferral) `WelcomeView.RecentArchiveRow` — is now one shared
  **`.hoverRowBackground(isHovering:isSelected:)`** modifier (`Views/HoverRowBackground.swift`; selection wins
  over hover, full-rect `contentShape`). **Reframe (agreed up front):** the audit's other half — "move the
  hand-rolled rows to `List`" — is **not taken and deliberately closed**: the metadata inspector is a
  `ScrollView` of stacked sections (slice 24), and nesting `List`s inside a `ScrollView` is a SwiftUI
  anti-pattern (scroll-within-scroll, indeterminate heights). The keyboard-traversal/selection that `List`
  would have bought is **F6**'s job, via `.focusable`/`@FocusState`, not `List`. Overlaps UI-audit **F8** (the
  add-affordance + hand-rolled-row half; the role-control half shipped slice 32). Pure app-layer, **no engine
  change** (135/132 engine + 6 CLI unchanged); all four affordances + all three row types live-verified.
  **F6 — Slice 35: menu bar + ⌫-delete + no window tabbing** (UI-audit F6, part 1 of 2 — the *menus* half; the
  focus-traversal + sheet-keyboard half is slice 36). The app was heavily click-driven — most artifact actions
  lived only as in-pane buttons, absent from the menu bar and shortcut-less. Now: a **View** menu adds
  **Show/Hide Inspector** (⌘⌥I — Finder/Calendar/Pages precedent; a *dynamic* Show⇄Hide label) and **Sort By**
  (the three F7 keys as a radio group + a per-key-phrased Ascending/Descending pair, checkmarked, bound straight
  to the model's `sortKey`/`sortAscending`); a new top-level **Artifact** menu gathers the artifact-scoped verbs
  (Add Event/Place/Person, Edit Transcript, Attach File, a **Selected File ▸** submenu — Open in Separate Window /
  Open in Default App / Save a Copy… / Replace… / Delete File… — and **Delete Artifact… ⌘⌫**, Finder's
  Move-to-Trash mapping, apt since our delete *is* trash-backed). (Post-review tweaks from live testing:
  **Artifact ▸ Attach File… goes straight to the importer** via `beginAttach` — *not* the Continuity
  connected-menu path, which floats a disconnected menu when popped from a menu-bar command with no anchor view;
  Continuity scanning stays on the in-pane paperclip / toolbar `+`. And the redundant **Show Preview** menu item
  + the per-file ⋯ **Quick Look** item were both **removed** — the document pane always previews the selected
  file, so selecting a row *is* previewing; this also **resolves UI-audit F10** by deletion rather than rename.) **Add Media** was renamed **Add
  Artifact** everywhere user-facing (File menu, the `+` connected-menu leading item, the undo action name) to
  distinguish creating an artifact from attaching a file to one; ⌘I stays Add Artifact (the inspector took ⌘⌥I,
  *not* ⌘I, to avoid the Get-Info collision without stealing ⌘I). **⌫ deletes the selected artifact** via
  `.onDeleteCommand` on the sidebar `List`, raising the *same* confirm as the context-menu/⌘⌫ path.
  **Routing plumbing** (the architectural core): the menu bar is a `Commands`, so it can't see the window's
  view-owned selection (`@SceneStorage` in the container / local `@State` in the detail view). `ArchiveModel`
  gained **read-only mirrors** (`selectedArtifact`, `selectedFile`, `inspectorVisible`) the views push *down* —
  purely so the menus can enable/label/target their commands; the views stay the source of truth and the model
  never writes selection back. Paired **one-shot intents** (`pendingArtifactCommand`, `pendingFileCommand`,
  `pendingArtifactDeletion`, `pendingInspectorToggle`, cleared after handling so the *same* command re-fires)
  let a menu ask a view to run a verb it owns — the detail view observes an intent and drives its **existing**
  sheet/handler state (no sheet code moved), the list observes the delete intent and raises its **existing**
  confirm, Attach routes to the model's `beginAttach` directly (see the Attach note below). This mirrors the
  established `lastCreatedArtifact` / `beginAddMedia` intent pattern. **Two gotchas fixed in-flight (both caught live):**
  (1) SwiftUI's `.disabled` on a submenu `Menu` grays its *children* but **not the submenu title** — AppKit only
  grays a submenu title when every child item is *individually* disabled, so "Selected File" stayed bright over
  disabled items until the `.disabled` was moved onto an inner `Group` wrapping the buttons; (2) the transcript
  editor sheet lived **inside** `inspectorContent`, so an Artifact ▸ Edit Transcript… command with the inspector
  *hidden* wouldn't present it (the subview isn't in the hierarchy) — it was hoisted to the top-level body chain
  beside the assertion sheet (the in-pane button and the menu both just set `isEditingTranscript`). **Window
  tabbing removed:** our value-based `WindowGroup(for: URL.self)` windows aren't tabbable documents, so AppKit's
  *Show Tab Bar / Show All Tabs / merge-into-tabs* machinery **crashed** when exercised — `NSWindow`.`allowsAutomaticWindowTabbing = false`
  in `applicationDidFinishLaunching` deletes those View-menu items entirely (Enter Full Screen is separate and
  stays). Pure app-layer, **no engine change** (135/132 engine + 6 CLI unchanged); every menu, shortcut,
  enable/disable, and routing path live-verified. Overlaps UI-audit **F6** (menus half).
  **F6 — Slice 36: focus-ring visibility + keyboard/a11y polish** (UI-audit F6 part 2 of 2 — the focus/keyboard
  half; also **resolves F11**). **Live testing reshaped the slice:** two of F6's three named keyboard gaps turned
  out to be **already handled by the framework** — a sheet auto-focuses its first text control (verified: typed
  into Add Event and the transcript editor *without clicking*), and a focused multi-line `TextEditor` already
  consumes plain Return as a **newline** (the Save button's `.defaultAction` was merely *shadowed* while editing —
  still the blue default, just never receiving the Return keystroke the editor ate first). So the real work was
  three smaller things: **(A)** the `AssertionRow` remove (trash) button was `.opacity(0.55)` until *hovered*, so a
  Full-Keyboard-Access user couldn't see it or its focus ring — now it reveals on `isHovering || removeFocused` via
  a per-row `@FocusState` (independent per `ForEach` row), so tabbing to it lights it up (dim → full + ring,
  live-verified). **(B)** `.accessibilityLabel` on the image-only controls VoiceOver previously announced as just
  "button" — `AssertionRow` trash → "Remove", `FileRow` ⋯ → "File actions", the document-header pop-out → "Open in
  separate window" (the toolbar `+` and the inspector `Label("Inspector", …)` already carry titles); this **closes
  F11**. **(C)** the transcript editor's Save moved from `.keyboardShortcut(.defaultAction)` to
  **`.buttonStyle(.borderedProminent)` + `.keyboardShortcut(.return, modifiers: .command)`** — the HIG-correct
  multi-line commit: plain Return stays the newline key (it belongs to the `TextEditor`), **⌘Return** commits
  (Xcode's commit-sheet precedent), and the button keeps its prominent blue look without `.defaultAction` claiming
  Return. **Deliberate non-goal (restated from slice 34):** *not* rebuilding `List`-style arrow-key row navigation
  in the inspector `ScrollView` — FKA already tabs through the buttons; the gap was the *dim/unlabeled* controls,
  not missing traversal. **/code-review nit fixed:** the ⋯ menu's `.help` was identical to its `.accessibilityLabel`
  ("File actions"), doubling the VoiceOver announcement — dropped the tooltip (the ellipsis is a conventional "more"
  affordance), keeping just the label. Pure app-layer, **no engine change** (135/132 engine + 6 CLI unchanged);
  ARCHITECTURE.md untouched (no architectural surface — routing/window-model/format all unchanged). A, B, C all
  live-verified. Overlaps UI-audit **F6** (focus/keyboard half) + **F11**.
  **EDTF dates — Slice 37 (engine; part 1 of 2).** Genealogical dates are usually uncertain, and plain
  ISO 8601 can't say the common things ("about 1920", "between 1900 and 1905", "before 1950"). Adopted
  **EDTF** (Extended Date/Time Format, ISO 8601-2 / Library of Congress), Level 0 + the genealogically-
  relevant Level 1 (approximate `~`, uncertain `?`, both `%`; intervals `1900/1905`; open ends `../1950`,
  `1920/..`; unspecified digits `192X`/`19XX`/`1920-XX`). **The key insight that makes this low-risk: EDTF
  is a strict *superset* of the ISO 8601 dates already stored, so every legacy `1920`/`1920-05-12` value
  is already valid EDTF — this is a grammar *widening*, not a data migration, and needs no format-version
  bump.** `Event.date`/`PersonFact.date` stay verbatim `String?` (authoritative); a new Foundation-free
  `EDTFDate.parse` (in `GeneaLogicModel`, Linux-safe — no `import`) derives `[lowerBound, upperBound]`
  bounds + qualification, **never stored** (consistent with "as-recorded" + "index is a rebuildable
  projection"). **No index/schema bump** — dates live in the artifact `json`, decoded in memory; there's
  no date column or `ORDER BY`. The two engine consumers of date strings were both ISO-string hacks that
  EDTF breaks, and both were generalized through the one bound API (good altitude): `earliestDate` (for
  `primaryDate`) moved from a **lexicographic** `.min()` to a bound-aware min returning the earliest
  event's verbatim string (so `19XX` correctly sorts before `1920`, where `'2' < 'X'` fooled the string
  sort); and `dateRange` filtering moved from a leading-4-digit-year prefix to **interval overlap**
  (`EDTFDate.overlaps(years:)`, open bounds = ±∞), replacing the deleted `leadingYear`. A value that isn't
  valid EDTF is skipped for ordering (kept as free text) rather than mis-sorted. **/code-review** (3 finder
  agents) caught one real bug — masked-year Feb 29 (`200X-02-29`) was wrongly rejected because the day was
  bounded by the *min* last-day across endpoints, but interior leap years make it valid; fixed by a bounded
  scan (`placeExplicitDay`) that finds the earliest/latest valid `(year, month)` placement → 2000-02-29…
  2008-02-29 — plus three cleanups (double-optional `classifyEndpoint` → `Endpoint` enum; `Range2` → stdlib
  `ClosedRange<Int>`; `daysIn` → `private`). Engine change → Linux-verified (166 macOS / 163 Linux + 6 CLI).
  **EDTF dates — Slice 38 (app + a shared model helper; part 2 of 2, delivering UI-audit F12).** The
  human-facing half of EDTF: dates are now *entered* forgivingly and *shown* readably. Four parts.
  **(1) Human-readable rendering** — a new **`EDTFDate.humanDescription`** (in the model, so it's shared +
  Linux-tested; still Foundation-free) glosses a stored value: `1920~` → "about 1920", `1900/1905` → "1900
  to 1905", `../1950` → "on or before 1950", `192X` → "1920s", `19XX` → "20th century" (a masked *century*
  is deliberately phrased differently from a masked *decade* so the two don't both read "1900s"),
  `1920-05-12` → "12 May 1920" (GEDCOM-style day-month-year — unambiguous and **locale-free**, since the
  model can't use `DateFormatter`). It renders from the source string's **structure**, not from the
  lower/upper bounds (the bounds discard precision — `1920` and `192X` both expand to a multi-day span but
  read very differently). Wired into the **event rows** (`EventsPlacesSection.eventSubtitle`), the **Primary
  Date caption** (which also shows the canonical EDTF beside "earliest event date" when the gloss differs, so
  stored precision stays discoverable), and the **sidebar `ArtifactRow` subtitle** — each falling back to the
  raw string when it isn't parseable (free text stays verbatim). **(2) Shorthand-acceptance** — a new
  **`EDTFDate.normalizingShorthand(_:)`** rewrites the common, unambiguous genealogist idioms to canonical
  EDTF **on commit** in the Add-Event sheet: `abt`/`about`/`c.`/`ca`/`circa 1920` → `1920~`, `bef`/`before
  1950` → `../1950`, `aft`/`after 1920` → `1920/..`, `1900-1905` & `between 1900 and 1905` → `1900/1905`,
  **month-name dates** `June 1920` → `1920-06` / `April 3, 1975` / `3 April 1975` → `1975-04-03` (full names +
  common abbrevs, comma optional, day-first or month-first), **decades** `1940s`/`1940's` → `194X` (which
  itself renders back to "1940s", a clean round-trip), and **lowercase masking** `192x` → `192X` (so
  the *stored* value is always canonical EDTF). Conservative and **output-validating**: each rule keeps its
  rewrite only if the candidate itself `parse`s, else the input is left as free text — so a rule can never
  manufacture an unparseable value, and an invalid calendar day (`April 31, 1975`) or ambiguous all-numeric
  order (`3 5 1975`) self-rejects to free text (this validation is also the /code-review fix; see below). **(3) The EDTF-aware
  date field (F12)** — the Add-Event Date field gained an EDTF example prompt and a **live, non-blocking
  gloss** beneath it: "→ about 1920" (after normalization) when it parses, a gentle "Not a standard date —
  it'll be stored as text." when it doesn't; **never disables Add** (genealogy must allow the unparseable).
  The gloss shows whenever the value parses — including plain ISO — as affirmative confirmation. **(4) The
  Primary Date sort** (app-side, from slice 28) moved from a raw-string compare to **`EDTFDate.parse(...)?.
  sortBound`**, so `192X` (1920) correctly sorts before `1921` where the lexicographic compare (`'2' < 'X'`)
  got it wrong; undated *and* unparseable-as-date values still sort last in both directions. **/code-review**
  (3 finder agents, this being a hand-written normalizer/renderer) caught a real class of bug: the shorthand
  normalizer validated each rule's *operand* rather than its *output*, so `about 1920/..` → `1920/..~` and
  `between 1900/1901 and 1905` → `1900/1901/1905` — both **unparseable** — would have been stored,
  contradicting the "output always parses" contract. Fixed at the root by validating the emitted candidate
  through `parse` (one `accept` helper, replacing the per-rule slash guards — better altitude); plus the
  century/decade gloss ambiguity (fixed above) and a widened round-trip invariant test (`normalizingShorthand(x)`
  is always unchanged-or-parseable, exercising the interval/range traps). Model change → Linux-verified
  (176 macOS / 173 Linux + 6 CLI). No format/schema/index change — `humanDescription`/`normalizingShorthand`
  are derived display/input helpers, nothing new is stored (the spec + ARCHITECTURE are untouched). Resolves
  UI-audit **F12** (only F13 = magic-number widths remains after).
  **F13 — Slice 39: named layout metrics (the last UI-audit item).** The content widths, sheet sizes, and
  small repeated chrome that were scattered as magic numbers through the views (`420`/`460`/`640`/`480`/`560`/
  `520`/`580`, `28`, `6`, `20`) moved into one **`Support/Layout.swift`** namespace of named `static let`
  constants — `Layout.fieldColumnMaxWidth`/`readableTextMaxWidth`/`fileNameChipMaxWidth`, `iconButtonHitSize`
  (the 28pt borderless-button hit area, ×3), `rowCornerRadius` (the hover/chip radius, ×4), `sheetPadding`
  (the 20pt sheet inset, ×4), and grouped sheet sizings: `Layout.ContentSheet` (the three content-heavy,
  freely-resizable sheets — integrity/trash/transcript — **unified** to one size, since their per-sheet
  drift `520`/`480`/`500` was incidental, not designed), `Layout.FormSheet` (the width-only assertion editor),
  `Layout.PreviewWindow` (the pop-out floor). Pure app-layer **refactor** — the only behavioral change is the
  ±20px content-sheet unification (all sheets stay resizable); deliberately left the assorted small paddings
  (8/10/12/16) and WelcomeView's self-contained numbers alone (naming those is noise beyond the "scattered
  widths" the audit named). Resolves **F13** — **the UI-audit backlog (F1–F14) is now fully worked**; next is
  the Phase 3 conclusions UI. No engine change (179 macOS / 176 Linux + 6 CLI unchanged).
- **Phase 3 (conclusions UI) — plan settled + slice 40 (engine foundation).** Phase 3 turns evidence
  into a concluded family tree; the shape was settled first (build plan in [`slices/phase-3.md`](slices/phase-3.md)): **manual-first** (create-person → resolve-mention → relationships → derived tree by hand; the
  `GeneaLogicMatch` matcher + suggested-links queue + `mergePersons` come after as a mini-phase), a **tab-bar
  UI** (window-level `TabView` — Artifacts / People / Tree — over the one shared `ArchiveModel`, chrome
  tab-scoped), and **inspector-primary resolution** (turn a `PersonMention` into a `Person` from the artifact
  inspector's Persons Mentioned section). **Slice 40** is the pure-engine foundation, before any UI. Read
  surface (`Archive+Lookup`): public **`relationships()`, `relationships(of:)`, `links(for:)`,
  `links(forArtifact:)`** — index-backed, uid-ordered (UUIDv7 = creation order), exposing the filtered views
  the person-detail + tree need over the index's existing `allRelationships()`/`allLinks()`. Mutations
  (`Archive+Conclusions`): **`updatePerson(_:_:)`** (person analog of `updateMetadata`; uid/schemaVersion
  immutable via this path) and the review-lifecycle removals **`removePerson`/`removeRelationship`/`unlink`**,
  each returning the deleted record with a paired **`restorePerson`/`restoreRelationship`/`restoreLink`** that
  rewrites the *exact* uid-faithful sidecar + re-upserts — so the app's `UndoManager` ping-pongs them like the
  artifact/file ops. Three deliberate choices (documented on the extension): **no manifest touch** (conclusion
  sidecars aren't in the BagIt payload); **in-session reversible, NOT trashed** — unlike artifacts (slice 20) /
  files (slice 21), since the manual loop is new and records are cheap to recreate (a cross-session conclusion
  trash — a `TrashEntry` `.person` kind — is a later follow-on, as ingest-undo predated the file trash); and
  **no cascade (§2.3)** — removing a person leaves referencing relationships/links *dangling* for
  `verifyIntegrity`/future `findDanglingReferences` rather than rewriting other conclusion records, which is
  also what keeps the removal reversible. Supporting: `ArchiveIndex` gains `relationship(_:)`/`evidenceLink(_:)`
  point lookups + `removePerson`/`removeRelationship`/`removeLink` deletes; `ArchiveError` gains
  `relationshipNotFound`/`evidenceLinkNotFound`. **No format/schema/index-version change** (the sidecars +
  vocab already existed; this is new read/write surface over them). Engine change → Linux-verified; 12 new
  tests (accessors, uid-faithful restore round-trips, no-cascade, survives-rebuild, not-found throws); **193
  macOS / 190 Linux + 6 CLI**, all green; /code-review clean. Next: slice 41 (tab-bar restructure + People
  browse/create/edit). ARCHITECTURE untouched (no new architectural surface — the conclusions model + §2.3
  separation are as designed in Phase 0).
  **Phase 3 slice 41 (app — the section-switcher restructure + the People tab).** The first Phase 3 *UI*:
  the open-archive window switches between **Artifacts / People / Tree** over the one shared per-window
  `ArchiveModel`. **The switcher is a segmented `Picker` in the toolbar's `.principal` slot (Calendar-style),
  NOT a window-level `TabView`** — this was settled *empirically*, reversing the initial "top tab bar" plan
  once the regressions showed. **The dead end (worth remembering):** a window-level `TabView` renders its tab
  bar in the **title-bar region**, which is exactly where a `NavigationSplitView` puts the window **title,
  sidebar toggle, and `.searchable` field** — so wrapping the section split views in a top `TabView` *displaced
  all three* (title gone, toggle relocated, search collapsed); and the `.sidebarAdaptable` `TabView` style
  (the "sidebar tabs" alternative) restored the chrome but **nested a `NavigationSplitView` inside a
  sidebar-style `TabView`** — a double-sidebar combo that was **layout-fragile (window-size glitches + a
  crash)**. The fix that keeps the chrome *and* stays stable: **one plain `NavigationSplitView`** whose sidebar
  + detail switch by `tab` (Artifacts↔People is a content swap, not a view-identity change, so column state
  persists), with **Tree a full-width `NavigationStack`** (it has no list). The segmented control centered in
  the toolbar reads like a tab bar without living in the title bar. (Known, accepted: a `.principal` item
  re-centers over the content region, so the switcher drifts when the sidebar/inspector toggles and jumps
  between Tree — no sidebar — and Artifacts/People; anchoring it in a full-width strip was offered and
  declined as over-chrome for now — revisit once People gains an inspector + Tree a sidebar in slice 44.) All
  the old single-archive chrome (Add `+`, `.searchable`, `ListControlsBar`, Continuity host, drag-in ingest,
  the menu-bar selection mirrors) lives in `OpenArchiveView`'s per-`tab` `switch`, **no regression**; the per-
  section `+` (Add Artifact menu / New Person) and search/prompt swap by tab; **`TreeTab`** is a
  `ContentUnavailableView` placeholder (real in slice 44). The window container gained
  `@SceneStorage("selectedTab")` + `@SceneStorage("selectedPersonID")` (per-window, restored like the artifact
  selection, slice 18) bridged to `ArchiveTab`/`PersonID?`. **People CRUD, undoable, over the slice-40 engine
  API** (no engine change this slice): `ArchiveModel` gained `persons`/`displayedPersons`/`personSearchText` +
  `reloadPersons`/`applyPersonFilter` (persons reload folded into `load()`/`refresh()`), and the mutations
  **`createPerson(given:surname:)`** (via `PersonDraft`'s convenience path; publishes `lastCreatedPerson` for
  auto-select, the People analog of slice 29's) and **`deletePerson`** — both undoable via the *same*
  restore↔redelete `UndoManager` ping-pong as artifacts (`registerPersonRestore`/`registerPersonRedelete`
  over the engine's `removePerson`→`Person`/`restorePerson`), but **in-session only, NOT trash-backed** (the
  slice-40 decision — conclusions are cheap to recreate; a cross-session `.person` trash is a later follow-on).
  Views: **`PersonListView`** (mirrors `ArtifactListView` — rows = display name over `primaryDate (EDTF-glossed)
  · N facts`, ⌫ + context-menu delete with a confirm that names the dangling-links §2.3 non-cascade,
  distinct empty/no-match states, `.searchable`); **`NewPersonSheet`** (given + surname, Create gated on one
  being non-empty); **`PersonDetailView`** — **read-only this slice** (name header + Names / Facts /
  Identifiers, dates EDTF-glossed, reloaded off `mutationVersion`); the **editable** person form (add/edit/remove
  names + facts with the EDTF-aware date field) is **slice 41b**. Menu-bar coherence: the model mirrors the
  **active tab** (`activeTab`) down so the **Artifact menu / Selected File / inspector toggle gate on the
  Artifacts tab being active** (`hasArtifactContext = selection ≠ nil && activeTab == .artifacts`) — no
  artifact command fires against a stale selection while People/Tree shows (verified live: the whole Artifact
  menu greys out on the People tab). Pure app-layer, **no engine change** (193 macOS / 190 Linux + 6 CLI
  unchanged); every flow live-verified (tab switching, Artifacts-tab regression-free, create+auto-select,
  read-only detail, undo/redo uid-faithful, sort, search, ⌫-delete+confirm, delete-undo, menu gating, Tree
  placeholder). ARCHITECTURE untouched (the window-model is still the value-based `WindowGroup(for: URL.self)`;
  a section switcher inside one window is not a new architectural surface). **/code-review (finder agents,
  actually spawned)** found no correctness bugs — the undo ping-pong, delete-undo selection recovery, `lastCreatedPerson`
  (no redo re-select race), and detail reactivity all check out — and three low findings, all applied: **Add
  Artifact… + View ▸ Sort By now gate on the Artifacts tab** (they were archive-only-gated, so they'd have
  acted on the hidden Artifacts list from People/Tree — a new `isArtifactsTab` helper beside `hasArtifactContext`;
  Sort By's *children* disable correctly, its submenu title staying bright is the slice-35 AppKit
  Picker-in-submenu quirk); **`PersonDetailView.displayName` now iterates all names for the first resolvable
  one** (faithfully matching the engine's `PersonSummary.displayName`, not just birth-or-first — reachable once
  names are editable in 41b); and the read-only **sections now use the sibling's `VStack` + primary `.headline`
  header** (not an inert `List` `Section`), so the People and Artifacts detail panes read alike. Next: slice 41b
  (editable person detail), then slice 42 (resolve a `PersonMention` → `Person`, inspector-primary).
  **Phase 3 slice 41b (app — editable person detail).** The read-only `PersonDetailView` (slice 41) becomes
  **editable**: the Names and Facts sections each gain an **Add** affordance, **tap-a-row-to-edit**, and a
  per-row **remove** — the People analog of the artifact inspector's Events & Places (slice 16) / Persons
  Mentioned (slice 19) sections. Every add/edit/remove commits through a new **`ArchiveModel.updatePerson(of:
  actionName:_:)`** — the person twin of `updateMetadata`: it loads a `before` snapshot, calls the slice-40
  engine `updatePerson(_:_:)` (identity immutable via that path), then registers a **snapshot-restore** undo
  (`registerPersonEdit` — before/after full-record ping-pong, the *edit* undo shape, distinct from the
  create/delete redelete ping-pong), so ⌘Z/⌘⇧Z reverse any change; a person removed out-of-band makes the step
  no-op gracefully. Edits are **by array index, bounds-checked inside the mutate closure** (a captured index can
  go stale before commit), the established Events/Persons-Mentioned pattern. The editor is a **new
  `PersonEditorSheet`** with a `.name(index:existing:)` / `.fact(index:existing:)` mode (`nil` index = add, set =
  edit-prefilled) — deliberately **separate from `AssertionEditorSheet`** (that sheet records *evidence* via
  `updateMetadata`; this records *conclusions* via `updatePerson` — keeping the two write paths in two sheets
  keeps the §2.3 boundary legible). Name form = a `NameType` picker (over `knownCases`) + given/surname/full;
  Fact form = a `FactType` picker + **the EDTF-aware date field** (live gloss + `normalizingShorthand` on commit,
  slice 38/F12) + place; an edited fact carries its `supportedByLinks` through untouched. Type pickers over the
  **open** vocabularies keep any `.unknown(...)` value authored elsewhere selectable by anchoring the option list
  on the record's **original** type, not the live selection (the /code-review fix — anchoring on the mutable
  selection would drop the unknown the moment a known case is picked). **Shared-view extraction** (the slice's
  altitude work, so nothing is re-implemented): `AddAffordanceLabel`, `LabeledField`, and `AssertionRow` (the
  last **generalized** with an optional `onEdit` that makes the row a tap-to-edit button — artifact rows pass
  `nil` and are unchanged; `.textSelection` is dropped only on the tappable People rows, as in the Files list)
  moved from `ArtifactDetailView`/`AssertionEditorSheet` into their own `Views/` files; the inline EDTF gloss
  became a shared `EDTFDateGloss`; the open-vocab picker-options rule became one
  `OpenVocabulary.pickerOptions(including:)` (de-duping the two artifact + two person copies); and name/fact type
  labels moved to `displayName` extensions in `Support/` (matching `FileRole`/`PersonRole`, replacing an ad-hoc
  static). **/code-review (finder agents, actually spawned)** found one real (minor) correctness bug — the
  live-selection picker anchor above — plus three cleanups (the ×4 options duplication, the labeling convention,
  a `label(for:)` forwarder), all applied; it declined splitting the bimodal sheet (it deliberately mirrors
  `AssertionEditorSheet`'s one-sheet-multi-mode shape). Pure app-layer, **no engine change** (193 macOS / 190
  Linux + 6 CLI unchanged); every flow live-verified (add/edit fact with shorthand-date normalization, tap-to-
  edit prefilled, undo/redo ping-pong, add name, remove+undo, display-name stays birth-preferred, sidebar
  subtitle + relaunch persistence, artifact-side AssertionRow regression-free). ARCHITECTURE untouched (the
  Person model + §2.3 separation are Phase-0 design). Next: slice 42 (resolve a `PersonMention` → `Person`,
  inspector-primary).
  **Phase 3 slice 42 (app — resolve a `PersonMention` → `Person`, inspector-primary).** The evidence→conclusion
  bridge: from the artifact inspector's **Persons Mentioned** section, each mention row now carries its
  **resolution state** — an unresolved mention shows a **Resolve…** affordance; resolving opens a new
  **`ResolveMentionSheet`** to either **link an existing** person (a searchable list, one **Link** per row) or
  **create a new** person seeded from the mention and link in one step. A resolved mention renders a tappable
  **chip** (`→ Anna Meyer · about 1892`, the person's display name + EDTF-glossed primary date) that **jumps to
  the People tab and selects that person**, beside an **Unlink** control. All conclusion-layer, over the slice-40
  `EvidenceLink` engine API (`link`/`unlink`→`restoreLink`, `links(forArtifact:)`); **no engine change**. New
  `ArchiveModel` surface (all undoable, in-session only per the slice-40 decision): `artifactLinks(for:)` (loaded
  in the detail view's `.task` beside the record, reloaded off `mutationVersion`), **`resolveMention`** (engine
  `link` + a `registerLinkRedelete` unlink↔restore ping-pong — the *link* create/delete shape, twin of
  `registerPersonRedelete`), **`unlinkMention`** (`registerLinkRestore`), and **`createPersonAndLink`** (adds a
  person seeded from `nameAsRecorded` — the exact string kept verbatim in the birth name's `full` plus a
  best-effort given/surname split — **and** links, registering both redeletes in one run-loop event so the
  window `UndoManager` groups them: **one ⌘Z removes both** the link and the new person, one ⌘⇧Z restores both
  person-first). Cross-tab jump is a one-shot **`pendingPersonNavigation`** intent (the navigate analog of
  `lastCreatedPerson`, but it also moves `tab`) the container observes → sets `tab = .people` + the scene-stored
  person selection. The mention row shows a **Resolve…** vs. chip+Unlink by matching `links.first {
  $0.personMentionRef == mention.localRef }`; a dangling link (person deleted) reads "Unknown person" (§2.3, no
  cascade). Evidence stays separate from conclusions: **Unlink removes only the link**, the mention (evidence)
  persists; **Remove Mention** (the row trash) deletes the evidence. **/code-review (finder agents, actually
  spawned)** found one real correctness gap — `createPersonAndLink` registered the person's undo *after* the
  `link` write, so a link-write fault after `addPerson` succeeded would strand an un-undoable orphan person;
  fixed by registering the person redelete *before* the link write (+ a `bumpAndRefresh` in the `catch` so the
  orphan still shows) — plus three cleanups, all applied: a shared **`RowRemoveButton`** (the F6 focus-reveal /
  hit-size / a11y trash chrome, de-duped from `AssertionRow` + the new mention row), a shared
  **`PersonSummary.browseSubtitle`** (the "date · N facts" line — the People list and the resolve picker had
  *drifted*, the picker hiding a zero fact count), and the resolve picker's search now runs through the engine's
  **`persons(matching:)`** (matching every one of a person's names, identical to the People tab's `.searchable`)
  rather than a display-name-only client filter. Pure app-layer, **no engine change** (193 macOS / 190 Linux + 6
  CLI unchanged); every flow live-verified (Resolve… → sheet, link existing → chip + Unlink, chip tap → People-
  tab jump + select, undo/redo link ping-pong, create-new-and-link + grouped ⌘Z removing both, engine-backed
  surname search, shared subtitle consistency, mention-trash regression-free, mentions persist across relaunch).
  ARCHITECTURE untouched (the `EvidenceLink` + §2.3 evidence/conclusions separation are Phase-0/slice-40 design).
  **Phase 3 slice 42b (app — the person "Sources" section).** The symmetric other half of slice 42's
  bridge: from a `Person`, see which artifacts cite it and jump *back* to the artifact — the reverse of
  slice 42's chip-tap. A new **Sources** section in `PersonDetailView` (below Facts, above Identifiers)
  lists one row per `EvidenceLink` citing the person, each showing the **citing artifact title** (a
  tappable accent link with an ↗ indicator) + the mention's **name-as-recorded** ("as recorded: …"),
  with an **Unlink**. Tapping the artifact does the cross-tab jump — `ArchiveModel.navigateToArtifact`
  sets the one-shot **`pendingArtifactNavigation`** intent (the exact mirror of `pendingPersonNavigation`,
  slice 42) the container observes → `tab = .artifacts` + the scene-stored artifact selection. New read
  surface `ArchiveModel.personLinks(for:)` (the mirror of `artifactLinks(for:)`, over the slice-40
  `links(for: PersonID)` engine accessor); the section is assembled in the detail view's `.task` off
  `mutationVersion` (a `[EvidenceLink]` → `PersonSource` rows, resolving each link's artifact title from
  `model.artifacts` and its recorded name from the artifact's full record, with a per-artifact
  `fullArtifact` cache since one document can cite a person more than once), so an unlink — from **here**
  or the **artifact side** (both bump `mutationVersion`) — refreshes it. **Unlink is the only mutation**,
  routed through the *shared* undoable `unlinkMention` (⌘Z restores the exact link, uid-faithful), so the
  person Sources section and the artifact resolved-mention chip are two doors to one link store. A
  **dangling link** (citing artifact deleted — §2.3, no cascade) still shows, as **"Unknown artifact"**
  with the jump **disabled** but Unlink **live** (so a stale link stays cleanable); a removed *mention*
  (localRef gone but link kept) simply hides the "as recorded" line. Evidence stays separate from
  conclusions: the Sources section is a read-through of `EvidenceLink`s, never editing the person or the
  mention. Pure app-layer, **no engine change** (193 macOS / 190 Linux + 6 CLI unchanged); **/code-review
  (8-angle) clean** (the one candidate — a seemingly-redundant `model.artifacts` title scan alongside the
  full-record load — is deliberate: the summary title stays correct even if the full record fails to
  decode, while `full` is needed for the recorded name); every flow live-verified (Sources display,
  cross-tab jump → Artifacts tab + select, Unlink → empty state, ⌘Z restore). ARCHITECTURE untouched (the
  `EvidenceLink` + §2.3 separation are Phase-0/slice-40 design).
  **Phase 3 slice 42c (app — record a person fact *from* linked evidence, human-confirmed).** The
  conclusion-layer analog of the §6.4 apply-suggestion flow: promote a linked artifact's evidence into a
  `PersonFact`, **never auto-copied** (§2.3 — an artifact's events aren't scoped to a mentioned person; a
  recorded age isn't a birth fact until a human derives it). A new **Suggested Facts** section in
  `PersonDetailView` (between Facts and Sources, hidden when empty) surfaces, per linked artifact, its
  `Event`s (**deduped per artifact** — events belong to the document, not a mention) and the resolved
  mention's `ageAsRecorded`, each a `FactSuggestion` row (`sparkles` icon + evidence line + "from
  <artifact>") with an **Apply…**. Apply opens the `PersonEditorSheet` in a new
  **`.factFromEvidence(FactSuggestion)`** mode: a read-only **Evidence / Source** context header (the
  conclusion-side twin of the assertion sheet's "Captured" row) + the §2.3 caveat subtitle, with the fact
  fields **prefilled** — an event's type via `FactType(parsing: event.type)` (so a non-standard type
  round-trips as `.unknown(...)`, still picker-selectable), its date/place carried over; a **recorded age**
  prefills type `.birth` but an **empty date** (the human derives the year from the age + the source's
  date, never auto-computed). Save appends a `PersonFact` with **`supportedByLinks: [suggestion.link]`**
  through the shared undoable `updatePerson` (⌘Z removes it), always an *add* (never edits an existing
  fact). The Facts row now appends a **"cited by N source(s)"** count (from `supportedByLinks.count`) so a
  promoted fact reads as evidence-backed rather than a bare assertion — otherwise the citation is invisible
  after applying. Apply is **additive** (a suggestion isn't consumed; you can promote the same evidence
  twice — your call, matching the artifact-side re-scan suggestions). **Altitude/reuse:** the Sources
  (42b) and Suggested-Facts rows are assembled in **one pass** — `loadLinkedEvidence() -> (sources,
  suggestions)` reads each linked artifact's full record once (per-artifact cache), so the new section adds
  no extra disk reads; the fact-building in `PersonEditorSheet.save()` factored into a shared `buildFact`
  used by both the manual `.fact` and `.factFromEvidence` paths (same shorthand-normalization); the fact
  fields extracted to a shared `factFields`. **/code-review (8-angle)** found no correctness bugs and one
  idiom cleanup, applied: `FactSuggestion.id` became a **stable** composite (`link.uid#e<index>` /
  `#age`) instead of a per-load `UUID`, so `ForEach` diffs the rows across a `mutationVersion` reload
  rather than re-creating them. Pure app-layer, **no engine change** (193 macOS / 190 Linux + 6 CLI
  unchanged); every flow live-verified (event + age suggestions render with source context, Apply →
  prefilled "Record Fact from Evidence" sheet → Save → "cited by 1 source", ⌘Z undo, the empty-date age
  path). ARCHITECTURE untouched (`PersonFact.supportedByLinks` + §2.3 are Phase-0 design).
  **42c follow-up fixes (user-reported, post-merge):** (1) the "Record Fact from Evidence" **Type picker
  showed a duplicate** entry for an event whose type only differs from a known case by **casing/whitespace**
  ("birth" → `.unknown("birth")`, which renders "Birth" beside the known `.birth`). Fixed at the parse site:
  `FactSuggestion.suggestedType` now maps an event type to a `FactType` **case/whitespace-insensitively**
  (`factType(forEventType:)`), folding those variants to the known case while keeping genuinely non-standard
  types (e.g. "Enumeration") as selectable `.unknown` options. (2) an **applied suggestion stayed in the
  list** — the additive design was wrong for the user; a recorded suggestion is now **dropped**:
  `loadLinkedEvidence(recordedFacts:)` filters via `isAlreadyRecorded` (a fact citing the same link with the
  suggestion's derived type/date/place — normalized the same way `buildFact` does on save), so applying one
  removes it and ⌘Z (deleting the fact) brings it back on reload. **/code-review** noted the matching is
  **heuristic** (a `PersonFact` doesn't record which evidence produced it): an *edited* apply, or a
  date-cleared event apply colliding with a same-link age suggestion, can leave/hide the "wrong" suggestion —
  accepted as a UI-convenience trade-off (the un-edited path, the common case, is exact), not worth a model
  change to store fact provenance. Both fixes app-layer, live-verified (lowercase "birth" event → single
  "Birth" picker option; Apply → suggestion disappears; ⌘Z → fact removed + suggestion reappears).
  **Phase 3 slice 43 (relationships — assert parent-child / couple, show relatives, remove).** The first
  Phase-3 **format change**, and it's a strict *additive* one: a **`facts` array on `Relationship`** so a
  couple carries its **marriage/divorce/annulment** date+place (a multi-person event is a fact on the
  couple, not duplicated onto each spouse — ARCHITECTURE §4.5). **The key low-risk insight: a pre-43
  `Relationship` sidecar has no `facts` key, so `facts` decodes to `[]` (custom `init(from:)` +
  `decodeIfPresent`) — a back-compatible *widening*, NO schema bump** (same superset reasoning as EDTF
  dates). **Sub-decision resolved: reuse `PersonFact`, not a distinct `RelationshipFact`** — GEDCOM X
  models Person and Relationship facts with one shared `Fact` shape, reuse adds the least new format
  surface ("format changes are the most expensive mistake") and lets the 41b fact editor serve both;
  `FactType` gained `.divorce`/`.annulment` known cases (`.marriage` already existed) + a **`coupleCases`**
  subset (for 43b's picker). **Endpoint convention resolved (was "unspecified" in the doc): parent-child
  stores `person1` = parent, `person2` = child** (couple symmetric) — the UI needs it to render roles;
  recorded in `Relationship`'s doc + ARCHITECTURE §4.5. Engine (Linux-verified, 201 macOS / 198 Linux + 6
  CLI): `updateRelationship(_:_:)` (couple-fact write path, the analog of `updatePerson`; endpoints
  mutable via the closure but the app doesn't expose that) + `relationship(withID:)` point lookup +
  `RelationshipDraft.facts`; round-trip-with-facts, back-compat-decode, and `updateRelationship`
  add/rebuild/not-found tests. **Format spec updated + a standing accuracy guard added:** §6.4 of
  `genealogic-archive-1.0.md` (the spec that ships *inside every archive*) documents the new `facts`
  field + the resolved `person1`=parent convention — edited in **both** checked-in copies (the docs
  `schema/…md` and the `Sources/GeneaLogicArchive/Resources/…md` that `Archive.create` bundles). New
  **`SchemaSpecTests`** (in the model target, reading the spec via `#filePath`) keeps the spec honest
  going forward: (1) the two copies are byte-identical (catches copy drift), (2) every stored field of
  every persisted record type is documented **in that record's own §-section** (section-scoped +
  matched as a backticked `` `field` `` token — a global substring check would've missed `facts`, which
  also appears under Person §6.2; verified as a real tripwire). This is the check that would have caught
  the `facts` omission — do the spec edit (both copies) whenever the format changes or it fails CI. **App (People-tab `PersonDetailView`): a new Relationships section** with
  a **perspective-based `RelationshipEditorSheet`** — the user picks whether the other person is a
  **Parent / Child / Partner *of the subject*** (a segmented picker + a live "…is a parent of Ann Smith"
  caption), never thinking in `person1`/`person2`; the sheet maps the choice to the §4.5 storage
  convention (Partner → couple; Parent → other=person1; Child → subject=person1), over the searchable
  person list with the subject **excluded**. Each relative row shows the role from the subject's view
  (Parent ↑ / Partner ♥ / Child ↓ icons, sorted parents→partners→children), **taps through** to that
  person (cross-tab `navigateToPerson`), and **removes undoably** (create↔delete redelete +
  restore↔redelete ping-pong, the same shape as person create/delete — in-session only, NOT trashed, per
  the slice-40 decision). **Dangling handling (§2.3, no cascade):** a relationship whose other person was
  deleted reads **"Unknown person"**, nav disabled but remove live; an **existing-but-unnamed** relative
  reads "Unnamed person" and **stays navigable** — the two are distinguished by *existence* (membership in
  `model.persons`), not by whether a name resolved (this was a **/code-review fix** — the first cut
  conflated them, wrongly disabling navigation to a real nameless person). **Altitude:** shared
  `PersonPickRow` + `PersonSearchField` extracted to `Views/PersonPicker.swift` (de-duped from
  `ResolveMentionSheet` — the resolve sheet + relationship editor now share them). **Scope split: couple
  marriage/divorce *fact editing* is slice 43b** (reusing the 41b fact editor over the landed
  `updateRelationship` path) — the format field + engine write path land in 43, the editing UI is 43b, so
  there's no second format change. **/code-review (8-angle)** found the unnamed-vs-deleted correctness bug
  (fixed) + the picker duplication (extracted) + a role-fallback doc nit (corrected); clean after. Every
  flow live-verified (create parent/child/partner, §4.5 convention correct from *both* sides, self-excluded,
  role sort, cross-tab jump, remove + ⌘Z restore, delete-person confirm §2.3 message, dangling "Unknown
  person" + navigable "Unnamed person", relaunch persistence). Next: slice 43b (couple fact editing).
  **Phase 3 slice 43b (couple relationship fact editing — a *unified Facts timeline*).** Add/edit/remove a
  couple's marriage/divorce/annulment over the `updateRelationship` engine path landed in 43. **The UX was
  reshaped mid-slice by live testing** (design fork put to the user, who chose it): the first cut edited couple
  facts *inline under the partner row* in the Relationships section, but that was poorly discoverable **and**
  left the person's Facts list reading as if it were missing their marriage. The chosen shape — matching how
  Gramps/Ancestry/RootsMagic show family events on a person — is a **unified Facts timeline**: a couple's
  marriage/divorce is **projected into the person's Facts section**, date-sorted (EDTF bound, undated last)
  among their own facts and tagged "· with \<partner\>". **Storage is unchanged** — the couple fact still rides
  `Relationship.facts` (§4.5); this is a *read projection* + **type-driven routing**. One **`FactEditorSheet`**
  (consolidating the old person-fact + couple-fact + 42c from-evidence editors — the couple-only
  `CoupleFactEditorSheet` from the first cut was deleted) drives every fact: the **type** decides the store —
  a person type (`FactType.personCases`, new) → `Person.facts` via `updatePerson`; a couple type
  (`FactType.coupleCases`) → a chosen partner's `Relationship.facts` via a new undoable
  `ArchiveModel.updateRelationship` (snapshot-restore ping-pong, the relationship twin of `updatePerson`). The
  couple case reveals a **"With" partner picker** (the person's existing couple relationships); recording a
  marriage therefore needs the partner relationship to exist first (no-partner → a hint + Save disabled). The
  type picker is **mode-scoped** so you can't convert a stored fact between stores by editing its type (add:
  all known; editPerson/fromEvidence: `personCases` + the record's own type; editCouple: `coupleCases` +
  own). `PersonEditorSheet` slimmed to **names only**; shared `FactFormFields` + `FactForm.build` (date-
  shorthand → EDTF) + a `pickerOptions(from:including:)` overload extracted. **Names stay in
  `PersonEditorSheet`, facts in `FactEditorSheet`.** **Sheet-sizing gotcha (a /code-review catch):**
  `.presentationSizing(.fitted)` fits the sheet to content **once** at open and does **not** regrow when
  picking Marriage reveals the "With" field mid-sheet — so the footer clipped. Fix: a per-mode **`minHeight`
  floor** (couple-capable modes reserve height up front) — but **not** an `idealHeight`, which *caps* the fit
  and would clip the taller static `.fromEvidence` mode (its long caption + evidence rows); `minHeight` alone
  floors the dynamic case while `.fitted` still grows the tall static one. **No format/schema/engine change**
  beyond the app-layer `updateRelationship` wrapper + `FactType.personCases` (201 macOS / 198 Linux + 6 CLI
  unchanged). **/code-review (8-angle)** found no correctness bugs and 4 minor issues, all fixed + verified:
  partner-options re-queried the index per render (cached in `onAppear`), the `idealHeight` sizing cap (above),
  a stale `CoupleFactEditorSheet` doc reference, and an optional-partner header ("…for this couple." when the
  spouse is unnamed/deleted). Every flow live-verified on a throwaway archive (add Marriage → "With" picker →
  Facts row "· with \<spouse\>", symmetric from both partners; mixed person+couple timeline date-sorted;
  edit Marriage→Divorce + ⌘Z; remove couple fact leaving the relationship + ⌘Z restore; no-partner Save-
  disabled; from-evidence sheet renders full). **Couple marriage/divorce with a *non-partner* or a
  suggested-marriage spouse is deferred to slice 43c** (the "Other person…" selector) — see [its spec](slices/43c-partner-aware-couple-facts.md).
  Pure app-layer; ARCHITECTURE untouched (the `Relationship.facts` field + §4.5 are slice-43 design).
  **Phase 3 slice 43c (partner-aware couple facts — the "Other person…" selector + spouse-on-suggested-
  marriage).** Closes the two gaps 43b left in couple-fact recording. **Before:** the Add-Fact "With"
  picker listed only a person's *existing* couple partners (so a marriage with a not-yet-partner meant
  creating the relationship first), and a marriage promoted from **Suggested Facts** (the 42c
  from-evidence path) recorded as a spouse-less *person* fact with no way to name a spouse. **Now:** the
  "With" control is a `Menu` listing existing partners **plus "Other person…"**, which opens a new
  **`CouplePartnerPickerSheet`** to pick **any** existing person **or mint a brand-new spouse inline**
  (given + surname — the user chose inline-create over pick-existing-only, the ROADMAP's open
  sub-decision). The chosen spouse resolves to a **`CouplePartnerChoice`**: reuse an existing couple
  relationship (an "Other person…" pick who's *already* a partner collapses back onto it — no
  duplicate), create a relationship with an existing person on save, or mint person + relationship +
  fact together. The from-evidence path now **offers couple types** (typeOptions widened from
  `personCases` to all `knownCases`) so a suggested marriage becomes a proper couple fact, and
  **surfaces the source record's people as spouse candidates** — the "With" menu lists every *other*
  person linked to the same artifact under a "Named on this record" section (`FactSuggestion` gained an
  `artifactID` for this), so the spouse is one click away even on a marriage record that also names
  parents/witnesses. **The original "auto-default only when `others.count == 1`" was the bug the user
  caught:** a real marriage record links the couple *plus* parents (4 people here), so the count was never
  1 and the spouse never appeared — listing candidates in the menu is the fix. The **default** is then
  chosen most-specific-first: (1) the person the record marks with the **`.spouse`** `PersonMention.role`
  when exactly one linked other has it (a second user ask — read the mention roles off the artifact and
  prefer the spouse), else (2) the record's only other named person, else (3) the subject's first existing
  partner. Role is used **only to sharpen the default, never to filter the menu** (roles are often left at
  the `.subject` default, so all named people stay listed). Candidates exclude the subject, existing
  partners (listed separately), and dangling links to deleted persons.
  Three new **grouped-undo** model methods over the landed engine surface (no engine change):
  `recordCoupleFact(between:and:fact:)` (create couple relationship + append fact — one ⌘Z removes
  both), `createPersonRelateAndRecord(subject:given:surname:fact:)` (mint person + relationship + fact —
  one ⌘Z removes all three), routed from `FactEditorSheet.recordCoupleFact` per the `CouplePartnerChoice`
  (`.relationship` still uses the plain `updateRelationship`). Registration order (person → relationship
  → fact) makes ⌘Z run fact-restore → relationship-remove → person-remove (LIFO) and redo the reverse,
  so each record exists when the one referencing it is (re)written — the `createPersonAndLink` discipline.
  Also: `loadLinkedEvidence` now dedupes suggestions against the person's **couple** facts too, so a
  marriage recorded onto a `Relationship` (not `Person.facts`) still disappears from Suggested Facts
  (extending the 42c dedupe). `FactType.personCases`/`coupleCases` unchanged. Pure app-layer, **no engine
  change** (201 macOS / 198 Linux + 6 CLI unchanged); every flow live-verified on a throwaway archive
  (marriage with not-yet-partner → relationship auto-created + grouped ⌘Z removes both; inline "Create &
  Use" new spouse → person minted + grouped triple ⌘Z; default-to-first-partner; symmetric projection
  from both spouses) plus the from-evidence pre-suggest observed read-only on the real archive (a
  suggested Marriage shows the "With" picker defaulting to the artifact's other linked person). **Live
  gotcha (cost a detour):** LaunchServices had the *skill's* stale `GeneaLogicApp-DD` build registered
  as the `.genea` handler, so `open` on the real archive routed to a **second, old** process — the
  from-evidence sheet first showed pre-43c behavior until the two processes were untangled (kill the
  stale build; the latest `xcodebuild` re-registers the fresh one). ARCHITECTURE untouched.
  **Phase 3 slice 44 (the derived Tree tab — hourglass).** The Tree placeholder becomes a real
  ancestors-and-descendants chart, in **two commits**. **Renderer decision, worth keeping: native
  SwiftUI, not SVG in a web view.** SVG doesn't lay out graphs — the layout pass is the same pure
  Swift either way — so a web view buys only the drawing while costing every interaction rebridged
  in JS (node tap, context menu, hover, all already native), the F6/F11 focus + VoiceOver work, and
  dark mode; and reaching for d3/dagre would vendor JS into a sandboxed app. `ImageRenderer` gives
  PNG **and PDF** export off the same view. **SVG's right home is the server:** the kit emits the
  projection, the app maps it to points, and Phase 4 (Vapor) maps the *same* projection to SVG.
  **Commit 1 — `TreeProjection` (`GeneaLogicModel`, Foundation-only, Linux-tested):** structure in
  abstract **slots, not pixels** (font metrics are UI — that's the seam), emitting `Node`, `Union`
  (+ `ParentEdge`) and `RepeatedPerson` cross-edges. **No `Edge` type** as first sketched — edges
  are fully derivable from unions plus node positions; only the repeat cross-edge isn't. Three
  derivations justify it being tested kit code: **union inference** (the format stores parent-child
  and couple as *separate* records and **never says which marriage a child belongs to**, so a
  child's union is derived by intersecting its parents against the couple records — precisely what
  a server renderer would otherwise reimplement); **pedigree collapse** (render once, later
  arrivals become cross-edges); **cycle guard**. **The layout is *not* Reingold–Tilford** — it is a
  DFS in draw order plus a per-generation cursor that only advances, giving no same-row overlap and
  disjoint subtree ranges for far less code; centering is a preference layered on top. **Commit 2 —
  the render:** `TreeGeometry` (the only slot→point conversion), `ZoomableCanvas`, `TreeContentView`
  (connectors in one `Canvas` behind real SwiftUI cards), focus picker + depth steppers, and the
  `personSelection` binding shared with People. **AppKit gotchas:** give the hosted document view
  the drawing's *intrinsic* size and **no** autoresizing (the opposite of slice 30's fit-to-window
  image variant) so one `NSScrollView` owns scrolling and zoom with no SwiftUI `ScrollView`
  fighting it; and **`NSHostingView` starts a *fresh* SwiftUI environment**, so the model needs
  explicit `.environment(model)` injection — the slice-11 sheet hazard in a new place. **Bugs worth
  remembering, none of which a passing suite caught:** an ancestor union was skipped when only
  *one* of two parents was fresh (pedigree collapse), rendering that parent unattached — and the
  **mirror of it on the descendant side** was left unfixed for a round, because the regression test
  I wrote only checked `generation < 0`; multiple marriages put a later union's drop point **on top
  of an earlier spouse** (partners now interleave around the person); the depth cut dropped
  **spouses**, which are same-generation, not one deeper; and a grandchild was **stranded far left
  under an unrelated uncle** because children are laid out *before* the parent claims its slot
  (fixed by shifting the whole child subtree right — always rightward, into space it already owns).
  Then `/code-review` found more: a **"No Relationships Yet" message shown to people who have
  relationships**, purely because the depth steppers were at 0 (only the *unpartnered* hit it,
  since partners had just stopped being depth-gated — the kind of asymmetry that survives casual
  testing); a main-actor-blocking rebuild (the projection is pure and `Sendable`, so it now runs
  detached, with `Task.isCancelled` guarding a superseded publish); an unsearchable flat menu of
  every person (now the shared `PersonSearchField`/`PersonPickRow` + engine `matchingPersons`).
  Fixing *those* exposed one more: **`ContentUnavailableView` sizes to its content rather than
  expanding**, so every empty state centred vertically and dragged the `.safeAreaInset` controls
  bar into the middle of the window — masked entirely by the canvas branch, where an
  `NSViewRepresentable` expands on its own. **No format/schema/index change.**
  **Phase 3 slice 44f (parent-child qualifiers + focus siblings).** There was **no way to record an
  adoption at all** — `RelationshipType` is `parentChild`/`couple` with no qualifier field. The
  standards-aligned fix needs **no format change**: GEDCOM X models these as facts on the
  *parent-child* relationship, and `Relationship.facts` already existed (slice 43), simply always
  empty for them. `FactType` gained the five parent-role cases + a `parentChildCases` subset — and
  **`personCases` had to *subtract* it**, or the person fact editor would have offered
  "AdoptiveParent" as a birth-type fact (a partition test now pins all three subsets disjoint and
  covering, so the next vocabulary addition can't repeat it). **Absence means *unspecified*, never
  "biological"** — a researcher who hasn't established a link's nature must not have one asserted
  on their behalf, so `BiologicalParent` is claimable deliberately and unqualified links draw
  solid. Settable at creation *and* retroactively (an always-visible per-row nature menu);
  `setParentChildQualifier` **replaces rather than appends**, the qualifiers being mutually
  exclusive answers to one question. **Siblings** are an `includeSiblings:` pass placed **last**
  (so they take slots right of the focus and its partners), drawn as **bare nodes** — expanding
  their partners and children is what turns a direct line into a cousin-fanning chart — and
  requiring `ancestorDepth >= 1`, since a sibling is only drawable once the shared parent has a
  slot to hang from. **Half-siblings are grouped by whichever *placed* parents they actually
  share**, so they hang from that one parent instead of implying a shared other. **Two live-only
  finds:** `.capitalized` rendered "AdoptiveParent" as **"Adoptiveparent"** (the vocabulary label
  prettifier now splits camelCase first — a latent bug for *any* camelCase vocab value); and a
  half-sibling's single-parent bus **fully contained** the full siblings' bus at the same height,
  merging into one line so you couldn't tell which parent a child hung from — exactly what the
  grouping exists to show (child-buses now get **lanes**). *Method note:* I first tried to settle
  that by squinting at zoomed screenshots and got contradictory readings; a data probe printing the
  union geometry answered it in one shot — **go to the data before the pixels.** Spec updated in
  **both** copies (the `facts` row said "a couple's event", which this widens).
  **Phase 3 slice 44b (CLI conclusions parity — the whole Phase-3 surface, headless).** The
  `genea` CLI had **zero** conclusions commands, so everything Phase 3 built was reachable only
  from the engine and the Mac app — and seeding a test archive meant clicking through the GUI (the
  friction slice 44's live test hit). Now: `person add|list|show|name(add|set|remove)|remove`,
  `mention add|list|remove`, `relate`/`unrelate`, `link`/`unlink`, `fact add|remove`, `trash
  list|restore|remove|empty`, plus `remove`/`detach` for artifacts and files. **No engine change** — the
  whole slice sits over the slice-40 API, which is the point: these tests are a second consumer
  with none of the app's assumptions (no `UndoManager`, no `@Observable`, no main actor), so
  Linux-green here is what de-risks Phase 4's Vapor reuse. 37 CLI tests, macOS + Linux.
  **Grammar: nouns for the new surface, flat verbs only where a verb joins two records.** With
  four record kinds a bare `add` can't say what it adds, so the conclusions surface groups under
  `person`/`mention`/`fact`/`trash`; only `relate`/`unrelate` and `link`/`unlink` stay flat. The
  Phase-1 verbs are left alone — they're artifact-scoped by convention and predate there being
  anything else to address.
  **Two scope gaps the plan didn't see, both found by *using* the thing, not by reviewing it.**
  (1) `link` resolves a `PersonMention` — and nothing in the CLI could **create** one, so `link`
  was unusable headlessly the moment it shipped; `mention add|list|remove` had to land with it
  (`localRef` **minted** as the lowest unused `p<n>`, never caller-supplied, mirroring the app's
  slice-19 rule, since it's an `EvidenceLink` anchor). (2) `trash` was unreachable for the same
  reason — nothing headless could delete an artifact or detach a file — so `remove`/`detach` landed
  too. The lesson both share: **a command that only *consumes* ids the other half of the app
  produces isn't shippable on its own.**
  **`person set` became `person name add|set|remove` — caught by a test, not by review.** The planned
  single setter edited a name *in place*, which quietly made a married/alias name unrecordable: a
  person could only ever have the one name they were created with. The failing test was one I'd
  written to prove `--match` searches *all* names, which is exactly the kind of test that finds a
  design hole rather than a typo.
  **One fact command for both stores** (`fact add --person|--relationship`), routed by target like
  the app's unified `FactEditorSheet` — `PersonFact` is the shape of both (§4.5), so two
  near-identical families would have been the wrong cut. Known fact types are **scoped to the store
  that fits them** (`personCases`/`coupleCases`/`parentChildCases`): a Marriage isn't a person fact
  and a Birth isn't a couple fact, which is a mistake worth catching — while an *unknown* type still
  round-trips, because the format's openness isn't negotiable.
  **Open-vocabulary options now parse case-insensitively** (`OpenVocabulary.parsing`): `--type
  birth` folds to `.birth` instead of minting an `.unknown("birth")` twin that renders identically
  but never compares equal — the exact drift the 42c follow-up fixed on the app side, latent here
  for every vocabulary option including the pre-existing `--media-type`/`--source-tier`.
  **Removals report what they left dangling.** §2.3 removals don't cascade, and a CLI has no undo
  stack to soften that, so `person remove`, `mention remove` and `remove` count the records that will dangle and
  say so at the moment it happens. That report is still the only *headless* notice — the
  `findDanglingReferences()` sweep landed in 44e but is surfaced in the **app's** Verify Integrity
  panel only; the **CLI's `verify` checks file integrity, not reference integrity**, so don't
  write "verify will catch it" anywhere until 44d exposes the sweep. Dangling endpoints render as `(deleted person)`/
  `(deleted artifact)` in `person show`, still printing the uid so the stale record stays actionable.
  README rewritten around the evidence/conclusions split, with its end-to-end example verified to
  run verbatim.
  **/code-review (3 agents: correctness, design/altitude, invariants+doc-accuracy) — 8 fixes, all
  applied and live-verified.** Four were real defects, and the pattern is worth keeping: *every one
  of them lived in the gap between two features that were each individually correct.*
  (1) **A freed `localRef` was re-minted onto a still-claimed ref**, silently re-binding a dangling
  `EvidenceLink` to a *different* person — a visible dangle becoming an invisible wrong conclusion.
  Both halves were tested (reuse; link-survives-removal); nothing composed them. The mint now skips
  refs `links(forArtifact:)` still claims. **The app's slice-19 copy of this rule has the same hole
  — promoted to slice 44c, the next one up.** (2) **`person name set` left `full` stale**, so the rename the README
  documents changed nothing visible (every consumer prefers `full`) and left the record
  self-contradicting; it now resynthesizes a `full` *we* synthesized while preserving an authored
  one. (3) **`trash remove` reported success for a uid that wasn't there** — the engine's delete is
  lenient, and this is the one path with no undo, so a fat-fingered digit read as "destroyed" while
  the entry survived to die later at `empty`. (4) **Parent-child qualifiers accumulated** via
  `fact add --relationship`, letting the CLI encode a two-natures state the app can't produce and
  silently drops; it now replaces, like the app's nature menu. Plus: self-relationships rejected;
  unknown vocab values stored **trimmed** (untrimmed input reintroduced the twin-value drift the
  case-fold exists to prevent); closed vocabularies moved to `ExpressibleByArgument` (ArgumentParser
  then lists valid values in `--help` *and* the error, exit 64 — strictly better than the
  hand-rolled check); `mention` takes its artifact positionally like every other single-target
  command; the three drifted out-of-range messages unified into `CLIUserError.outOfRange`; and
  `fact add`/`person name add` print the minted index as a **data column** (the `attach` precedent)
  so it composes with `--index`. 37 → **45 tests**.
  **`ArchiveSubcommand` now covers every archive-scoped command, old and new.** The protocol
  (path → `Archive.open` → do the work → `ExitCode`) was first applied only to the 15 new
  commands, leaving the Phase-1 eight spelling the wrapper out — two shapes for one thing in one
  target. Migrating the rest surfaced two contracts worth knowing: **`stderr` has to reach every
  command** (only `attach` uses it, for its non-fatal duplicate-content note, but a command that
  can't reach stderr would have to opt out of the protocol entirely — one uniform signature beat a
  second protocol for one case), and **a deliberately-thrown `ExitCode` must pass through the
  wrapper untouched** — `verify`'s "the run succeeded, the report isn't clean" contract would
  otherwise be reported as a failure, printing a nonsense `Error: ExitCode(rawValue: 1)` after a
  perfectly good report. `create` is the one command left out, and correctly: it has no archive to
  open, it makes one.
  **`ls`/`rm` renamed to `list`/`remove` everywhere** (top level and inside `person`/`mention`/
  `fact`/`trash`), Swift types included (`LsCommand` → `ListCommand`, `PersonRmCommand` →
  `PersonRemoveCommand`, …). They were the last unix-terse abbreviations in a surface that is
  otherwise all words — `add`, `show`, `attach`, `detach`, `relate`, `restore`, `verify` — so
  they were the odd ones out rather than the convention. No aliases were kept: nothing has
  shipped against the old names (44b isn't merged), and one name per command beats two.
  **Phase 3 slice 44c step 1 (the `localRef` re-binding bug — app + a shared model rule).** The
  app could re-mint a freed `PersonMention.localRef` that a surviving `EvidenceLink` still
  claimed, silently re-binding that citation to a **different person**. Removing a mention leaves
  its links dangling on purpose (§2.3, no cascade); minting the lowest *unused* `p<n>` then handed
  the freed ref to the next mention, and the stale link resolved again — a visible dangle becoming
  an **invisible wrong conclusion**, which is the worse direction: the Sources row reads plausibly
  and is simply false. (The app's own comment claimed "never a reused identity", which is exactly
  what it did.)
  **Why it survived:** both halves were tested — ref reuse, and links surviving a removal — but
  nothing composed them. 44b hit the identical hole in its own new copy and fixed it there, which
  is what surfaced the app's.
  **The fix is the consolidation, not a patch.** Minting is a **format-level rule** — every
  consumer must mint identically or they disagree about what a link points at — so it now lives in
  the model as **`PersonMention.nextLocalRef(in:claimedBy:)`**, and the app's and CLI's copies are
  deleted. A freed ref is still reused (no upward drift); it's only skipped when a link still
  claims it. 7 model tests, Linux-verified (251 → **258**), and the key one is
  **mutation-checked** — reverting the rule fails it, which the two original copies' tests never
  would have.
  **Verified in the app, in the data.** The scenario was seeded headlessly with the new 44b CLI
  (artifact → mention → person → link → remove mention), then the mention added through the
  *inspector* — the actual bug site — and the result checked with `genea mention list` /
  `person show` rather than by reading pixels: the mint returned **p2**, and the citation shows a
  dangle instead of naming the new person. **Seeding a GUI bug repro from the shell is exactly the
  payoff 44b was built for**, one slice later.
  **A constraint found while scoping the rest (worth remembering): the open-vocabulary case-fold
  must NOT move into `OpenVocabulary.init(parsing:)`.** That's the **decode** path — folding there
  would rewrite stored values on re-encode (`.unknown("birth")` → `.birth`) and break the
  unknown-preserving round-trip guarantee, a worse bug than the duplication it would fix. It's
  *input normalization* and belongs in a separate helper the app and CLI call at their input
  boundaries.
  **/code-review (2 agents: correctness, design+invariants) — both independently found the same
  top defect, in the *app*: `PersonEditorSheet` was the one writer never routed through the shared
  rule, so editing a name part re-saved the prefilled `full` and the rename was invisible
  everywhere while the fields said otherwise — the exact failure `hasDerivedFull` exists to
  prevent, sitting in the file the slice didn't touch.** Two independent reviewers converging on
  it is the signal worth keeping: *consolidating a rule is only half the job; the other half is
  finding every writer, and a `grep` for the old code doesn't find the one that never had it.*
  Fixed (Add/Edit Name now go through `deriving` + `hasDerivedFull`) and live-verified. Also
  applied: **`claimedBy:` lost its `[]` default** — a defaulted guard is opt-in, and a future
  caller omitting it would silently restore the bug with nothing failing; the empty case is now an
  explicit `claimedBy: []` at the call site. Plus stale-doc fixes (a dangling reference to the
  deleted private `displayName`, a prose restatement of the moved rule, the header test counts)
  and a `summarize` note that the move also *normalized* two degenerate cases, so it isn't
  mistaken for a pure code move.
  **Step 2 — the consolidation itself.** All four rules now live in `GeneaLogicModel`, every
  hand-written copy deleted: `PersonMention.nextLocalRef(in:claimedBy:)`, `PersonName.resolvedText`/
  `hasDerivedFull`/`deriving(...)`, `Person.displayName`, and `OpenVocabulary.parsingLeniently`.
  The engine, app and CLI all forward. **Placeholders stay with the consumer** ("Unnamed person" /
  "(unnamed)" / an empty column in `person list`, so `cut -f2` can't mistake decoration for a
  name) — only the *derivation* is shared. **The copies had already drifted**, which is the whole
  argument: the app trimmed whitespace and the other two didn't, and the engine's `full` synthesis
  left a **leading space** when `given` was blank — which would also have made `hasDerivedFull`
  fail to recognize its own output and treat a derived `full` as authored. Resolved toward the
  stricter reading (whitespace-only is not a name). 258 → **272** macOS / 269 Linux; 45 CLI
  unchanged; app builds and its People pane spot-checked live. Note the trim helper had to go from
  `fileprivate` to internal. (The first version of this note claimed the model is "Foundation-free"
  — **wrong**, and caught in review: the contract below is *Foundation-only*, i.e. Foundation is the
  one permitted dependency and the ban is on AppKit/UIKit/SwiftUI/Combine. The real reason is
  narrower: `EDTFDate.swift`/`Enums.swift`/`Person.swift` are deliberately **import-free**, and
  reusing that helper keeps the new rules that way.)
  **Phase 3 slice 44e (`findDanglingReferences()` — the referential sweep + the integrity
  panel).** §2.3 removals don't cascade, so deleting a person or a mention deliberately leaves
  stale pointers behind. The app already reads them gracefully at the point of display
  ("Unknown person" / "Unknown artifact", 42b/43) — but only if you happened to look at that
  row. Now they're **findable in one pass**, reported in the existing Verify Integrity sheet
  beside Corruption / Stray Files.
  **It is a second engine call, not a new `IntegrityReport.Issue`.** That report answers "is the
  BagIt payload exactly what `manifest.json` says", hashes files, and explicitly does not audit
  `conclusions/`; this one resolves pointers and hashes nothing. The structural tell is that
  every `Issue` case carries a `path` — which the app's grouping, tint and row identity all key
  off — and a dangling reference has none, so folding it in would have meant the first case that
  breaks an accessor every other case satisfies. Two sweeps, one panel, one `Findings` payload
  so the panel can't render one against a stale other.
  Seven finding kinds, each naming the surviving **holder** first (the record a human would edit
  or delete) and the missing target second. A **missing artifact suppresses the mention finding**
  for the same link, or one broken link double-counts. Persons/links are bulk-loaded so existence
  is a set test; **artifacts stay point lookups**, because bulk-loading them to test membership
  would decode every `record.json`.
  **The order is contract, and pinning it needed a test that asserts the whole array.** The
  index's `SELECT`s carry no `ORDER BY`, so the sweep sorts — and /code-review demonstrated that
  deleting all three `sorted(by:)` calls left the entire suite green, because every assertion was
  either a single-element `==` or a `contains`. The ordering test is now mutation-checked.
  **The one real defect /code-review found:** the sweep opened with an all-or-nothing
  `guard let … else { return [] }` over the three bulk reads, so a single undecodable record
  collapsed it to "nothing dangling" — and since nothing else audits the conclusion sidecars, the
  panel would then affirmatively state that *every conclusion points at a record that still
  exists* having never read them. Degrading **per kind** was the fix. Worth generalizing: a
  read-failure path that returns the same value as "all clear" is a lie waiting to be printed.
  **Phase 3 slice 44g (repairing dangling references — user-reported off 44e).** 44e made the
  dangles *findable*; this makes them **fixable**. The trigger was a bug: a resolved mention
  whose person had been deleted still rendered the accent "→ person" chip, so clicking it
  switched to the People tab and selected **nothing**. Two lessons in one row. (1) *A dangling
  pointer must not be drawn as a live affordance* — it now reads as a muted **Missing person**
  badge (not a button) beside **Re-resolve…**. (2) The row conflated **existence** with **name
  resolution**, so an existing-but-nameless person also read "Unknown person" and offered a jump
  to nowhere — the exact bug slice 43 fixed for relationship rows, sitting unfixed one file over.
  Whenever one row learns that distinction, go check its siblings.
  **Repair, don't just delete.** A person-shaped dangle keeps a true assertion ("this document
  names someone", "this person has a parent") attached to a wrong identity, so substitution is
  the right verb: **Re-resolve…** (artifact mention) and **Replace Person…** (relationship
  endpoint) both *replace* — unlink-stale + link-new, or rewrite the endpoint the missing uid
  identifies (so §4.5's `person1Uid`-is-parent survives without the caller thinking about it).
  Grouped so **one ⌘Z reverts the whole repair**. The person **Sources** row deliberately gets
  *no* substitution: repointing a citation at a different document would falsify the evidence
  (§2.3) — Unlink is the only honest repair there, which is a distinction worth keeping.
  **The integrity panel became actionable**: per-row **Reveal** + **Remove Stale Reference**
  (every case routed through an existing undoable mutation — no new kind of write).
  **Two things only live testing / review caught, both about a sheet not being its window.**
  (1) **⌘Z does nothing while the panel is up** — a sheet is its own key window, so the archive
  window's `UndoManager` is out of reach until it closes. The step *is* on the stack; the help
  text now says so instead of the usual "(⌘Z to undo)". (2) By the same separation, the model's
  `actionInfo`/`actionError` alerts are bound on the window *behind* the sheet, so a failure or
  notice raised from inside it never reaches the user at the moment they clicked — the panel now
  owns a **sheet-local alert** and drains `actionError` into it. Rule of thumb: **anything a
  sheet needs to say or undo, the sheet must own.**
  **Reveal is offered for only 3 of the 7 finding kinds** (both review agents caught this
  independently): a stale `supportedByLinks` citation is drawn *nowhere* (a fact shows "cited by
  N sources" — the count, never which), and a link whose **mention** is gone has no row either,
  because the Persons Mentioned section iterates mentions and the row is precisely what was
  deleted. Revealing those dismisses the panel onto a page that looks entirely normal, having
  thrown away the only thing that named the problem — so `isRevealable` gates the button, and
  Remove Stale Reference is their fix. **A navigation affordance is only honest if the
  destination renders the thing you navigated for.**
  Engine: one accessor, `evidenceLink(withID:)` — the missing sibling of `person(withID:)`/
  `relationship(withID:)`; both `links(for:)` calls are *filtered views*, so a bare link uid had
  no way to reach its endpoints.
  **Follow-on: the `PersonPickerSheet` consolidation** (done, same branch). Adding
  `ReplacePersonSheet` made **four** hand-written copies of one sheet — with
  `ResolveMentionSheet`, `CouplePartnerPickerSheet`, `RelationshipEditorSheet` — each repeating
  the `searchText`/`results` pair and its reload, the sizing block, the `ScrollView`-of-
  `PersonPickRow` list, the centred empty state and the Cancel footer. **The copies had already
  drifted before anyone looked**: four action verbs (Link/Add/Select/Use) and two empty-state
  rules. The shell now owns all of that; each sheet keeps only what actually differs — its
  wording, its extra controls, and what happens on select. **The two `@ViewBuilder` slots are
  the whole design**: an `accessory` between header and search (the relationship editor's
  kind/nature pickers, the partner picker's inline new-person form) and a `footerLeading` beside
  Cancel (the resolve sheet's "create a person from this mention"). Everything else is a
  parameter. **−247 lines.** Two small generalizations fell out: the no-match wording derives
  from `excluding` ("No people" vs "No **other** people"), and "is there anybody to pick at
  all" derives from the candidate set rather than a raw `persons.count <= 1`, so it stays right
  however the exclusion is used. The sheets **still own their writes** — the shell only presents,
  so each sheet's §2.3 boundary stays documented where it's enforced. `TreeTab`'s focus picker
  is deliberately left alone: it's a *popover*, not a sheet, and already reuses the two shared
  pieces (`PersonSearchField`/`PersonPickRow`).
  **Phase 3 slice 44d (CLI evidence-layer parity + read surface).** 44b brought the *conclusions*
  surface to the `genea` CLI; 44b's own audit scoped this — the **evidence** side was still partial
  and the read surface thinner than the engine's. Pure `GeneaLogicCLI/`, **no engine/format/schema
  change** (over the settled slice-40/44e API, exactly like 44b). New commands: **`event add|remove`
  / `place add|remove`** — the load-bearing part: a document's dates/places were unwritable
  headlessly, the gap between "seed a family" and "seed a family *from documents*"; `event`'s
  `--date` runs through `EDTFDate.normalizingShorthand` like `fact add`, and both are index-addressed
  (bounds-checked *inside* the `updateMetadata` closure — and since `updateMetadata` returns `Void`
  unlike `updatePerson`, the minted index is captured in the closure, as `mention add` captures its
  `localRef`). **`show`** — the artifact register, the flat analog of `person show`. **`set-role` /
  `replace-file`** — flat file verbs over `setFileRole`/`replaceFile`. **`lookup`** — the four exact
  point lookups (`--at-path`/`--external-id`/`--sha256`/`--mentions`), one command, mutually-exclusive
  modes (`--mentions <PER>` is the conclusions-aware complement to `find --mentioning <text>`).
  **`relationship list`** — the flat whole-graph view. Extended: **`set-meta`** gains `--language`,
  `--original-format`, `--external-id scheme=value` (+clear) and `--retrieval-*` (source+date required
  together, +clear); **`find`** exposes the whole `ArtifactQuery` (`--tag`/`--source-tier`/
  `--from-year`/`--to-year`/`--mentioning`, AND-combined with an optional free-text query — the
  positional `query` became optional); **`verify`** now also runs `findDanglingReferences()` and
  prints a **Dangling references** section, **informational only** — file-integrity issues alone drive
  the non-zero exit (a resolved fork; dangling refs are the expected §2.3 residue the removal commands
  already nudge you to clean up, so the `mention remove`/`person remove` doc comments now point at
  `verify`). **Three design forks settled with the user up front:** flat `set-role`/`replace-file`
  (not a `file` noun); one `lookup` command (not facets on `find`); the informational-verify choice.
  **/code-review (self, on the working diff) found one real defect:** `find --from-year 2000 --to-year
  1900` **fatal-errored the process** — a reversed pair traps `(lower)...(upper)` (`ClosedRange
  requires lowerBound <= upperBound`, SIGTRAP), a raw Swift trap not a usage error; now a clean
  `CLIUserError`, regression-tested (the one-sided `Int.min`/`Int.max` bounds are safe against
  `overlaps(years:)` — pure comparisons, no arithmetic). New `EvidenceCommandTests` (15 tests) →
  **45 → 60 CLI tests**; engine untouched (193 macOS / 190 Linux). The shared `CLIUserError.outOfRange`
  gained a `see:` param so artifact-side edits point at `genea show`; a shared
  `ExternalIdentifier.parsing(token:)` (splits on the first `=`) is reused by `set-meta`/`lookup`; a
  new `ArtifactFormat` renders the evidence register beside `ConclusionsFormat`. README rewritten with
  the end-to-end example verified to run verbatim. Deliberately out of scope (unchanged): the
  `restore*`/`revert` undo primitives (need an in-process token a one-shot CLI can't hold — `trash` is
  the durable door), `repair()` (throwing stub), `fileURL(of:in:)` (in-process preview accessor). This
  is the **last 44-series *evidence-CLI* slice**; the format revision (44h) followed.
  **Phase 3 slice 44h (matcher-precursor format revision — the format the matcher will read,
  settled before the algorithm).** Five planned changes plus a sixth nobody planned. Engine +
  model + CLI + spec; the app was touched only as far as compiling and staying honest, with the
  *authoring* UI deferred to **44i**. 292 macOS / 289 Linux engine + 67 CLI.
  **(1) §10.6 resolved toward mention-scoped facts — via a new `RecordedFact`, NOT `PersonFact`,
  which reverses the plan.** An artifact's `events[]`/`personsMentioned[]` are flat and unpaired,
  so on a multi-person record — a census household, a metrical register, a marriage certificate
  naming the couple *and* both sets of parents, i.e. this project's norm — nothing said **whose**
  recorded birth was whose. Each `PersonMention` now carries its own `facts[]`. The type
  question is the interesting part, because the answer is the **opposite of slice 43's on the
  same question**: 43 reused `PersonFact` for `Relationship.facts` because a relationship *is* a
  conclusion, so its `supportedByLinks` means what it says. On a *mention* that same field points
  into `conclusions/` — an evidence sidecar citing a conclusion, inverting §2.3's one-way
  dependency — and would sit there permanently empty. **A second small type costs far less than
  a format in which evidence can cite conclusions.** *Generalizable: "reuse the existing type"
  and "don't reuse it" can both be right for the same shape; what decides it is which layer the
  fields belong to, not how similar the structs look.*
  **`RecordedFact` also carries an optional per-fact `informationQuality`** — unplanned, but §4.6's
  per-***field*** GPS quality is one of the three matcher inputs the slice was scoped around, and
  a mention-wide value cannot express it (a death certificate is primary for the death it records
  and secondary for the birth it mentions). **Absent means *inherit the mention's*, never
  `undetermined`** — forcing a value would fabricate a judgment nobody made, the same rule as the
  parent-child qualifiers and `sourceDerivation`. `FactType.recordedCases` = `personCases` **plus**
  `coupleCases` (a marriage register's entry for the groom really does record his marriage) minus
  `parentChildCases` (a parent-role qualifier describes a concluded *edge* between two identities,
  so it can't be an observation about one named person).
  **(2) `Artifact.sourceDerivation`** (`original`/`derivative`/`authored`) — the GPS axis
  orthogonal to the genre-shaped tier: a register page and an online index typed from it are both
  `church` and are not equal evidence. **(3) Name language/script**, on `PersonName` *and*
  `PersonMention` (`nameLanguage`/`nameScript`). Both fields, not "and/or" — they're orthogonal, a
  transliterated Russian name being language `ru`, script `Latn`, and it's the **script** that
  picks a phonetic keyer. **(4) `PersonRole` opened** + six register roles (godparent, sponsor,
  declarant, registrar, clergy, midwife); it was the one closed vocabulary among the record-role
  set, and closed meant a record carrying an unlisted role **failed to load**. **(5) Scores → `Int`
  0–100** (float text isn't canonically reproducible without JCS/RFC 8785).
  **(6) The one the plan missed: the score type change silently misreads every existing link.**
  A pre-44h link stores `1` (Double `1.0` = *certain*) in all four score fields; as `Int` that
  reads as **1, i.e. 1%**. The real archive had 12. The plan's own argument for doing it now —
  "almost none are persisted yet, only trivial human-link values" — was *also* what made it
  silently wrong: those trivial values are exactly the ones that misread. **Resolved with the
  user: accept it, no schema bump** (pre-release, single user, artifacts backed up independently;
  a `1.0 → 1.1` bump before a 1.0 has shipped buys machinery, not safety). *The lesson worth
  keeping: a type change is only cheap while the values are meaningless — and a constant
  placeholder is not the same as no data.* Found by the **golden JSON fixture**, which refused to
  decode `0.6` into an `Int`; the silently-wrong `1` case only surfaced from there by going and
  reading the real archive's bytes.
  **CLI (so the matcher has seedable data without app UI):** **`genea mention fact add|remove`** —
  deliberately **not** folded into `genea fact`, because 44b's justification for one fact command
  was "`PersonFact` is the shape of both", which stops holding the moment the type *and the layer*
  differ; nesting under the evidence noun mirrors `person name add|set|remove`. Plus
  `--source-derivation` on `add`/`set-meta` (with `--clear-source-derivation` — a settable optional
  needs a route back to *unstated*), `--name-language`/`--name-script` on `mention add`,
  `--language`/`--script` on `person add` + `person name add|set`, and `genea show` nesting a
  mention's facts under it with the indices `mention fact remove` takes. `--role` moved **off**
  `ExpressibleByArgument` (an open vocabulary can't be rejected at parse time) onto the lenient
  case-folding parse — which flipped an existing test from "rejects `bystander`" to "preserves it",
  the test *becoming* the record of the behavior change.
  **Engine:** free-text search and the `dateRange` facet now cover mention-scoped facts — both
  purely additive (whatever matched before still matches), and without them the facts scoped to a
  mention would be the one thing a record states that neither surface can reach. **Deliberately
  NOT changed: `earliestDate`/`primaryDate` still derives from `events[]` only** — that's a
  *value* change, not an additive one, and it's UI-visible (the app captions it "earliest event
  date"), so 44i owns it. Spec updated in **both** copies; `SchemaSpecTests` is what forces that.
  **/code-review (8 inline angles) — 9 findings, all fixed.** The one that mattered was in the
  **app**, in a file the slice barely touched: `PersonEditorSheet.save()` built a fresh
  `PersonName` from its four fields and did `person.names[index] = name` — a **whole-value
  assignment**, which silently destroyed `language`/`script` on every name edit, including a
  one-character typo fix, for any name the CLI had tagged. *The generalizable rule: adding a field
  to a record is only half the job; the other half is finding every writer that **replaces** the
  record rather than mutating it — and grepping for the new field name can never find them,
  because they predate it.* Fixed at the right altitude: the sheet now assigns the fields it
  **owns** rather than the whole value, so the next field added is preserved by default (opt-in
  loss, not opt-out). Verified by seeding a tagged name with the CLI, editing the surname in the
  **app**, and re-reading the sidecar — the 44b/44c payoff again, and note the sheet has **no**
  language/script fields, which is exactly why whole-value assignment was silently lossy.
  Also fixed: **CLAUDE.md's own Non-negotiables contract** still listed the open vocabularies
  without `source derivation` / `person role` — the slice updated three *other* statements of that
  rule (Enums.swift, spec §7, ARCHITECTURE) and missed the governing one; **two formatters written
  in this same slice had already drifted** (`mentionLine` tested non-empty, `nameLine` tested
  `!= nil`, so `language: ""` rendered `[/]` on one side and nothing on the other, and both emitted
  a dangling `ru/` when only one tag was set) — now one shared `languageScriptTag`; **`mention
  remove` destroyed a mention's recorded facts silently**, which is *owned data with no CLI undo*
  and so a stronger case for the family's "say what this removal cost" rule than the dangling links
  it already reported; `recordedFactLine` duplicated `factLine`'s type/date/place prefix (now a
  shared `factParts`); `RecordedFact.informationQuality(within:)` shadowed the property it read
  (renamed `effectiveInformationQuality` — and the rename **immediately** broke the call sites with
  "cannot call value of non-function type", confirming the arity-only resolution the finding
  described); `--role`'s help named 4 of 11 known roles after `ExpressibleByArgument` was dropped
  (now generated from `knownCases`, since losing the value list is how `.unknown` twins get typed);
  and a new **`artifact-44h.json` golden fixture** covers the post-44h encoding — `artifact.json`
  is now purely the *back-compat* input, leaving no fixture showing what the encoder writes, and
  the new test additionally pins the fixture's own bytes against the encoder, which `assertFixture`
  deliberately doesn't do (it compares two re-encodings, so a key renamed in both model and fixture
  would slip through). 293 macOS / 290 Linux + 69 CLI.
  **Phase 3 slice 44i (the app surface over 44h's fields — plus a small format revision the
  testing surfaced).** Scoped as "UI over 44h's landed fields," it grew a deliberate *additive*
  format change once real data (a relative's *Declaration of Intention to Naturalize*) showed the
  fact model had no home for **value-bearing** facts — an occupation "tailor", a physical
  description "brown hair, 5 ft 8 in". Engine + model + CLI + spec + app; **295 macOS / 292 Linux
  engine + 70 CLI** (the model changes are stdlib/Foundation-clean, so the format work is
  Linux-safe); /code-review clean (8 angles, **zero findings**).
  **(1) The format change: `value: String?` on BOTH `RecordedFact` (evidence) and `PersonFact`
  (conclusion).** Additive and back-compatible — the fact structs use *synthesized* `Codable`,
  whose optional decode is `decodeIfPresent`, so an absent `value` reads as `nil` with **no schema
  bump** (§4.2's superset reasoning, the same treatment `facts[]`/`Relationship.facts` got). GEDCOM
  X-aligned (a `Fact` there carries type + date + place + **value**; `Occupation`/`PhysicalDescription`
  are exactly the value-bearing types). **The user chose this over the attributes bag** (untyped,
  unmatchable): a value on the fact promotes cleanly from evidence to conclusion and is first-class.
  Three `FactType` cases promoted from `.unknown`: `declarationOfIntention` (US "first papers"),
  `occupation`, `physicalDescription` (the long tail stays free-entry). **`FactType.valueBearingCases`/
  `isValueBearing` is advisory, NOT a constraint** — value is permitted on any type at the format
  level; the classification only drives which editors show the Value field by default (an `.unknown`
  custom type counts, since this build can't know it isn't value-bearing). A partition-style test
  pins the classification.
  **(2) The bug the promoted multi-word types exposed: `parsingLeniently` was never actually
  whitespace-insensitive.** Its own doc claimed "case- and whitespace-insensitively", but it only
  trimmed the *ends* — so a human typing "Declaration of Intention" folded to `.unknown(...)` sitting
  beside the PascalCase known `.declarationOfIntention` ("DeclarationOfIntention"), the exact twin the
  lenient fold exists to prevent. Fixed to collapse **internal** whitespace too (known raw values
  contain none), so multi-word input folds while a genuinely off-list multi-word type is still
  preserved verbatim. This is a **general** fold-behaviour fix (every open vocabulary's input path),
  not just facts. *Lesson: a promoted vocabulary value is only as reachable as the parse meant to
  recognize it — and a doc-string can lie for every slice before someone types the case that tests it.*
  **(3) Spec + fixtures:** the `value` field documented in both spec copies (`SchemaSpecTests` doesn't
  reflect into these nested inline-documented types, so it's by-hand discipline, not a tripwire); a
  value-bearing fact added to the `artifact-44h.json` golden fixture to pin the encoding; value
  round-trip + value-absent back-compat decode tests. **Engine:** free-text search now covers fact
  `value` on both the artifact and person haystacks (additive). **CLI:** `--value` on `fact add` /
  `mention fact add`; `genea show` renders it quoted.
  **(4) App — the bulk, all live-verified:**
  - **Mention-scoped recorded-fact editor** (`RecordedFactEditorSheet`): the load-bearing piece — the
    app couldn't see or write a `PersonMention`'s `facts[]` at all. Each mention row in the inspector
    now shows its recorded facts (tap-to-edit + remove) with an **Add Fact…** affordance; Type scoped
    to `recordedCases`, EDTF date, and the optional per-fact **Information Quality** override with an
    "Inherit from mention" (`nil`) default.
  - **A real mention edit path** (`PersonMentionEditorSheet`, add + edit): mentions never had one —
    now the name row taps to edit name/role/quality/age + `nameLanguage`/`nameScript`. This **removed
    person handling from `AssertionEditorSheet`** (now event/place only), matching the People-tab's
    names-sheet/facts-sheet split.
  - **The other 44h fields surfaced:** a **Source Derivation** picker in the artifact details;
    `PersonName.language`/`script` in `PersonEditorSheet`; a shared `languageScriptTag` rendering
    "ru/Cyrl" on both mention and name rows.
  - **42c suggestions rewired to mention facts** — Suggested Facts now come from the resolved mention's
    own `facts[]` (scoped to the person, §10.6) instead of the artifact's unscoped document-level
    `events[]`; the per-artifact event dedup retired.
  - **Custom fact types** via an **"Other…"** picker option revealing a free-text field (open vocab,
    folds via `parsingLeniently`), and the **Value** field shown only for value-bearing types
    (`isValueBearing`) but **never hidden while it holds text**, so a value is never stranded.
  - **`primaryDate` decision: kept events-only** (the user's call) — a mention-scoped fact never pulls
    the artifact's "earliest event date"; no engine change, caption unchanged.
  **(5) Then a round of hand-testing feedback, all shipped:**
  - **The person is named in the recorded-fact sheet heading** ("Add Recorded Fact — Sura Rozen") — you
    click Add Fact under one of several mentions and need to know which.
  - **One-click Record** on each *directly-recordable* suggestion (a person-type `RecordedFact`): a
    **Record** button that saves the un-edited fact in one click (undoable, dedupes the suggestion out)
    beside **Edit…**. A **couple** fact (needs a spouse) and a **recorded age** (needs a human-derived
    year) are *not* one-click — they keep **Apply…** (the sheet). The rule: directly-recordable → Record
    + Edit…; needs-input → Apply…. *This is why the age has no Record, which read as inconsistent until
    framed as "an age isn't a fact, it's a datum you derive a year from" — it groups with couple facts,
    not with births.*
  - **"Add as name" on the person's Sources rows** — the recorded name is a *name*, not a fact, so it's
    never a Suggested Fact; it only auto-seeds on *create-from-mention*. For the *link-existing* case the
    document's own spelling (a Yiddish form, a married name) went uncaptured. Now each Sources row offers
    **Add as name** when the recorded name isn't already one of the person's names — opening the name
    editor **prefilled** (Full Name = the recorded name; the human sets type + given/surname split),
    undoable, the affordance vanishing once added.
  - **Sheet height-floor fix** (the slice-43b `.fitted`-doesn't-regrow gotcha, resurfaced): adding a
    *conditional* Value/Custom-Type row to a `.fitted` form with no height floor let the rows shove the
    header off the top and the footer off the bottom. Named floors in `Layout.FormSheet`
    (`compactMinHeight`/`minHeight`/`tallMinHeight`) reserve room up front (never `idealHeight`, which
    *caps*). *Lesson: adding a field that appears mid-sheet re-arms every `.fitted` sheet's clip hazard.*
  **Altitude/reuse:** value threads through one `FactForm.build` + `factParts` (CLI) + one
  `FactSuggestion` evidence case; the mint/fold/display rules stay in `GeneaLogicModel`
  (`parsingLeniently`, `nextLocalRef`; `languageScriptTag` app-side). **Every editor assigns only the
  fields it owns** — the whole-value-assignment data-loss class this project keeps re-finding — so the
  mention/name editors preserve `facts`/`localRef`/`language`/`script` and `editPerson` carries
  `supportedByLinks` through. **Deferred to the 45+ matcher mini-phase (the user's call): a cross-person
  suggested-facts/links *triage inbox*** — one-click Record smooths the per-fact path now; the planned
  "suggested-links queue" is where a batch, cross-person review belongs. ARCHITECTURE untouched (the
  `value` field + §2.3 evidence/conclusions separation are Phase-0/44h design; no new architectural
  surface). §10.6 stays resolved (44h).
- **Phase 3 slice 45 (the matcher's scoring core) — `GeneaLogicMatch` exists.** New Foundation-only
  target over the model; **no archive, no I/O, no format change** (295→378 macOS / 292→375 Linux, +83).
  **The seam is the design decision:** input is two plain views (`PersonMatchView`,
  `MentionMatchView`), never an `Archive`, so scores are reproducible from data you can write in a
  test and Phase 4 can reuse the scorer without the engine. Projecting an archive into those views is
  45b's, deliberately on the other side.
  **D–M shipped as specced and the table is faithful** (JewishGen chart examples pass verbatim).
  **The keyer's honest failures are pinned as tests**, which is the entry's real content: `Fay`/`Faye`
  **key apart** (`AY` codes `1` before a vowel and nothing word-finally, so a silent trailing `e`
  changes the key) and the archive records them as one person — caught only by the Jaro–Winkler band,
  which is the concrete vindication of folding edit distance into slice 45 rather than deferring it
  with the second keyer. `Zelig`/`Sidney` correctly *doesn't* match: an americanization is not a
  sound, and `knownVariant` stays unproduced until a variant table exists. *(Corrected in 45b: this
  was written as `Szlama`/`Sidney`, who are **father and son** in the archive — keying them apart is
  a true negative, so the docs and two tests were pinning a false negative the keyer never had.
  Lesson: a golden pair asserts a fact about the corpus, and a wrong one teaches a future slice to
  break working code.)*
  **The table branches more than the published chart's examples show, and that is accepted** (checked
  by hand against the chart): `Peters` keys `739400` *and* `734000` because the `RS` rule (`94` or `4`)
  fires across the `Peter`+`s` boundary, and `Auerbach` branches on `CH` by design. The chart promises
  only that *its* code is among ours, which is what `DaitchMokotoffTests` asserts (`contains`, not set
  equality — worth knowing that's the assertion strength). Extra codes err toward recall: more pairs
  reach `.phonetic` and are then graded down by Jaro–Winkler, so the cost lands on 45b's candidate
  precision, not on correctness.
  **`MatchKind` is closed, so a near miss needed a home:** reporting it `.phonetic` would lie (no
  keyer matched), `.none` with a non-zero score is self-contradictory — so it is `.within` with
  `delta` carrying how far off, the one existing case whose meaning ("inside a tolerance") fits.
  **Two defects the tests found, both in the scorer, not the expectations.** (1) The exact band
  compared token *arrays*, contradicting the token-set rule documented four lines below it — so a
  surname-first register would have been demoted to a near miss. (2) **The roll-up could not
  distinguish a bare name match from one corroborated by birth year, place and spouse**: a weighted
  mean over one perfect dimension and over four are both 100, which makes the top of a review queue
  meaningless exactly where it matters. Fixed with a corroboration factor (only *agreeing* dimensions
  count — a disagreeing one is a conflict, not breadth). *Lesson: a mean cannot express breadth, and
  the aggregate's only job is ordering.*
  **Absence is never a zero** anywhere in the scorer — an unassessed dimension is `nil`, an unstated
  `sourceDerivation` is not `original`, an absent per-fact quality inherits the mention's. The GPS
  weights **discount, never erase** (floor 0.6): a compiled tree with four agreeing dimensions is
  still a real suggestion, and deciding otherwise is the researcher's call, not the matcher's.
  Place matching treats **a matching town under a different country as strong agreement** — the
  partition case, where string equality is exactly wrong.
- **Phase 3 slice 45b (candidate generation + `suggestLinks`) — the scorer meets a real archive.**
  `Archive+Matching.swift`; no format change (378→396 macOS / 375→393 Linux, +18), CLI and app
  untouched.
  **The specced phonetic-key pre-filter was dropped for brute force**, which is the entry's real
  content. A key gate would have made 45's `.within` band **unreachable from an archive**: `Fay`/`Faye`
  key apart (45's own pinned failure) and are one woman in the corpus, so the gate would have deleted
  the pair before the band that catches it ever ran. A gate wide enough to keep it must stay a
  *superset of everything the scorer can score* — an invariant with no compiler check and no
  exhaustive test, which rots the first time a threshold moves and whose failure mode is an invisible
  false negative. Neither entry point is quadratic over the archive, so it bought nothing. *Lesson: a
  pre-filter is a claim about the scorer that the scorer doesn't know it's making.*
  **Layering beat the API sketch:** §6.3 showed `Matcher.suggestLinks(for:in:)`, which puts the
  archive *under* the matcher. Shipped as a method on `Archive` (Archive → Match → Model) so the
  scoring core stays archive-free and Vapor-reusable; §6.3 amended rather than obeyed.
  **The skip rules are the slice's semantics, not plumbing.** A `.humanConfirmed` link resolves that
  mention **for everyone** — re-offering it to a second person would be asserting the two are the same
  person, which is 45f's question, not the evidence queue's. A `.humanRejected` tombstone forecloses
  **that pair only**. `.machineSuggested` on disk (never written by us) is ignored: an unreviewed guess
  is not a human decision. Rejection tombstones are hand-written into `conclusions/links/` in the test
  and the index rebuilt — 45c owns the reject *entry point*, and reading the sidecar is the stronger
  assertion anyway. `matchScore(of:against:)` applies neither threshold nor skip rules, so 45d's
  `match explain` can stay engine-free as specced — the pairs worth explaining are exactly the ones
  the queue hides.
  **Gotcha, and it passed a wrong test first:** `#expect(x?.kind == .none)` resolves `.none` to
  `Optional.none`, silently turning "the name didn't match" into "did this return nil?". Spell the
  type (`MatchKind.none`) whenever the left side is optional.
  **Validated against a copy of the real archive** (15 mentions, 14 already linked by hand, so the
  human's links are an answer key): **14/14 recovered, 14/14 with the correct person ranked first**,
  runner-ups no higher than 26 against a lowest true positive of 67 — the default floor of 50 sits in
  a wide gap. The one pair above the floor the user hadn't linked is correct. `Faye Hanner` → Fay
  Hanner scores 80 through `.within` + spouse/parents corroboration, which is the dropped key gate
  vindicated on live records. Two things the run does **not** show: the phonetic band is never
  exercised (`Marcus Hanner`→`Hanaur` reads `exact`, because that person carries both spellings), and
  at this size nothing stresses brute force. Also surfaced a data question for 45d's tuning pass:
  15 of 20 artifacts are tagged `compiled`, including a marriage record, costing that whole cluster
  ~15–20 points of source weight.
  **Four `/code-review` findings, all fixed on the branch, and the second is the instructive one.**
  (1) `matchScore` built a whole-archive corpus — every artifact and link decoded, under the lock —
  to score one pair; the corpus now reads only what each entry point needs (`forSuggestion` /
  `forScoring`, artifacts always passed in). (2) **The code contradicted its own comment**: the
  artifact direction was O(persons × relationships) because `personView` scanned every relationship
  per candidate, while the comment, ROADMAP and SLICE-LOG all claimed "neither entry point is
  quadratic." Bucketing relationships by endpoint once makes the claim true rather than retracting
  it. *Lesson: a performance claim written in prose is not checked by anything — this one was wrong
  the moment it was written down.* (3) A negative `limit` tripped `Array`'s "subrange start is
  negative" precondition, which fires in release, so a read-only query could crash the app over its
  own argument; now clamped, non-positive means empty. (4) `public import GeneaLogicMatch`, since
  `SuggestedLink.match` hands `ScoredMatch` across the boundary — without it every consumer must
  depend on a module it never names.
  **Plus a self-referential-relationship guard** found while reasoning about the review: `other(from:)`
  returns the *same* person for a self-edge, so a person became their own spouse (and own parent),
  and any co-mention sharing their surname would then read as a plausible `spouseName` agreement —
  silent, and on this corpus the common shape rather than a contrived one.

- **Phase 3 slice 45c (the review lifecycle) — a suggestion becomes a decision, and a "no" is
  remembered.** `Archive.confirm`/`reject` write an `EvidenceLink` carrying **the matcher's real
  dimension scores**, `createdBy: .machine` + `Matcher.toolIdentifier`, `reviewedBy`/`reviewedAt`
  set. A `nil` `match:` is scored in place, so the CLI can reject a bare pair. Spec §6.3 +
  ARCHITECTURE §4.4 updated in both copies; no field added, no schema bump.
  **A confirmation is a verdict on the pair, not a re-scoring of the evidence.** The stored score is
  *not* raised to 100 because a human agreed — a link confirmed on a birth year three years off must
  still say so a decade later, and `link()`'s honest-minimum breakdown stays the right record for a
  mention resolved unaided. Both paths kept; `link()`'s "flagged for Opus review" note is resolved
  rather than deleted.
  **A tombstone is what gives an ephemeral matcher memory.** Suggestions are never persisted, so
  without a stored rejection the identical pair is recomputed and re-offered forever. It stores the
  computed breakdown too: a rejection of a *strong* match is where the matcher is wrong in a way
  worth understanding. Un-rejecting is `unlink` — a tombstone *is* an `EvidenceLink`, so no fourth
  verb. §4.4's example JSON showed a persisted `machine-suggested` record — now corrected to
  a confirmation, with the "legal on disk, never written by us" rule stated in both spec copies.
  **A pair holds one verdict** — `link`/`confirm`/`reject` each replace any existing link for the
  triple, returning it in `ReviewDecision.superseded` (plus `strandedCitations`) so undo can repair
  it. *This reverses the fork as originally settled*, which allowed same-status duplicates on the
  reasoning that a repeat is redundant rather than contradictory. **True of confirmations, false of
  rejections:** each tombstone forecloses the pair independently and `unlink` is uid-addressed, so
  un-rejecting would remove one, report success, and change nothing the user can see — a trap laid
  directly under 45d's `match unreject`. Review caught it; the narrower repair (special-case
  rejections) was rejected for the uniform rule, since "it depends which status you're writing" is
  what the next caller gets wrong. `link()` had the same hole from the other side: reject-then-
  resolve-by-hand left both records, and unlinking the confirmation foreclosed the pair forever
  behind an invisible tombstone. *Lesson: "duplicate" and "contradictory" are not the same
  predicate, and which one a repeat falls under depends on what the record **does**, not on whether
  its fields match.*
  **The audit was the slice, and it found one real bug.** `PersonMention.nextLocalRef` must skip any
  ref a *surviving link* claims — and a tombstone claims one exactly as firmly. Reading the filtered
  list there would let a removed mention's ref be reissued, silently re-aiming a recorded "this is
  not Szlama" at whoever now holds `p3`. Two call sites (CLI `mention add`, the app's mention editor,
  via a named `refClaimingLinks`). *Lesson: "hide rejections" is not a global rule — the question is
  whether a surface means **citation** or **record on disk**, and only the first hides them.* Same
  reasoning kept tombstones visible to `findDanglingReferences()` and to the removal warnings that
  restate it. `links(for:)`/`links(forArtifact:)` filter by **default** with `includeRejected: true`
  as the opt-in, so a call site added next year that thinks about none of this is still safe;
  `evidenceLink(withID:)` stays unfiltered (refusing a uid the caller holds reads as corruption).
  `EvidenceLink.isRejection` exists to be greppable — the mistake this guards against is a *missing*
  check, and a named predicate is how the audit stays done.
  **The artifact direction is now grouped per mention** (`[MentionSuggestions]`, replacing the flat
  return 45b shipped): scored pairs can only report matches, so a mention nothing matched vanished —
  making "no mentions", "all resolved" and "a name the archive has never seen" the same empty result.
  The third is the *somebody new* case, the only one with work attached, and it was invisible. An
  empty candidate list is **not** evidence the person is new: the matcher's blind spot is precisely
  the name it can't recognize, so 45e must show what a zero floor turns up beside any create action.
  `limit` is per mention now — three candidates for the first name and none for the rest is not a
  queue. 426 macOS / 423 Linux (+27) + 70 CLI; new `ConfirmRejectTests`, one test per audited
  consumer, deliberately repetitive because each is a separate chance to have missed a filter.
  **Also from review:** superseding deleted a link without reporting the `supportedByLinks`
  citations it stranded — every other removal path in the engine tells the caller what it cost at
  the moment it happens, so `ReviewDecision.strandedCitations` now does too (computed only when
  something *was* displaced, and pinned equal to what `findDanglingReferences()` reports so the two
  can't drift). And a `try?` on `allLinks()` inside the supersession loop would have silently
  skipped supersession on an index read error — writing the contradictory record the loop exists to
  prevent, with an empty `superseded` so no undo could repair it; now `try`, like every other index
  read in that function.

- **Phase 3 slice 45d (`genea match`) — the matcher becomes reachable and tunable.**
  `match suggest|explain|confirm|reject|unreject`; CLI-only apart from one engine fix review found
  in 45c's committed code (below); no model, spec or app change. Confirms the 45b re-export bet:
  the CLI names `ScoredMatch` without declaring a
  dependency on `GeneaLogicMatch`, because `public import` says the matcher's vocabulary is part of
  `GeneaLogicArchive`'s API.
  **Both suggestion directions print the same six columns**, columns 1–3 being exactly the triple
  the four other verbs take, so a suggestion pipes into a decision unreshaped. The engine returns
  different *shapes* for the two directions (flat vs. grouped); making a script branch on which
  question it asked would be leaking that inward.
  **A mention nothing matched is a row, not an absence** — 45c's grouping would be pointless
  otherwise. Its empty columns are `-`, not empty: consecutive tabs collapse under a shell `read`'s
  default `IFS`, so a mid-row empty silently shifts every later field left. (`person list` prints an
  empty name column for the same class of absence — but that one is *trailing*, and the rule is
  about position, not taste.)
  **The gotcha the hand-run caught:** that row first blamed the confidence floor, unconditionally.
  A candidate is dropped for **two** reasons — under the floor, or foreclosed by a tombstone — and
  the engine's result cannot tell them apart, so a user who had rejected the only candidate would
  lower `--min-confidence` forever while the fix was one `match unreject`. The row now counts the
  rejections on that mention and says so. *Lesson: a message that names a cause the caller only
  guessed at is worse than one that names none.*
  **`unreject` clears every tombstone on the pair, and refuses a confirmation.** The first honors
  the promise it makes (the pair returns to the queue) even against an archive a foreign writer left
  duplicates in — the trap 45c's one-verdict rule closed going forward, but only for records this
  version wrote. The second is because both are `EvidenceLink`s, the CLI has no undo, and a verb
  named "unreject" must not silently un-resolve a mention; the error names `genea unlink` instead.
  `String.padding(toLength:)` **truncates**, so `known-variant` would have rendered as an algorithm
  that doesn't exist — replaced with a pad that only ever grows.
  **The tuning pass (a copy of the real archive, links stripped, re-derived through the CLI):
  14/14 recovered, 14/14 ranked first, 14/14 above the default floor** — lowest true positive 74,
  highest runner-up 30, so 50 sits in a 44-point gap. It also made 45b's data question concrete:
  **no artifact in the corpus sets `sourceDerivation` at all**, and `compiled` is a catch-all for
  twelve records that are originals (draft registrations, a naturalization certificate, an arrival
  manifest), costing them ~50 points of source-authority weight. Recall survives on the name
  dimension alone, which is exactly why it went unnoticed. Half of it is cataloguing; the other
  half is a real gap — the tier vocabulary has no bucket for civil records that aren't vital
  registration — now specced as **slice 46**, deliberately on records-honesty grounds rather than
  scoring ones (retagging moves the weakest true positive 74 → 77, and the `vital` ceiling only
  reaches 86, because the roll-up bounds the source discount to `0.6...1.0` on purpose).
  **`/code-review` found a data-loss ordering bug in 45c's *committed* code**, fixed here because
  deferring a destructive one is not a scope decision worth making: `link`/`confirm`/`reject`
  deleted the pair's existing verdict *before* writing the replacement, and `withState` has no
  rollback — so a failed write destroyed the old verdict **and** threw, so no `ReviewDecision` came
  back and neither the CLI's displacement line nor the app's `registerLinkRestore` could name what
  was lost. The user is told it failed while their confirmation is silently gone. `supersedeLinks`
  split into a read (`linksForPair`) and a delete (`supersede`), with the delete moved after the
  write. **Recoverable inconsistency beats irrecoverable loss:** the new failure window holds *two*
  links on a pair — visible, addressable by uid, cleared by the next write — where the old one held
  none. Safe because `link`'s primary key is `uid` alone, so the index represents the pair fine, and
  `withState` holds the lock across both halves so no in-process reader sees it. *Not unit-tested:
  distinguishing the two orders needs an I/O fault seam this suite doesn't have, and the read-only-
  directory trick fails both orders identically. The success-path supersession tests still pin the
  semantics, including that the new link survives.*
  Two smaller review findings, both false signals rather than crashes: `--limit 0` clamped to zero
  results and printed the *nothing-matched* row for a mention with a perfect candidate — a "this may
  be somebody new" claim produced by a flag, so a non-positive limit is now refused (only the
  `--limit=-1` equals form reaches the guard; with a space ArgumentParser rejects `-1` as an option
  name first). And an empty `nameAsRecorded` put a blank column *mid-row*, the exact `IFS` collapse
  `absentColumn` exists to prevent — the rule is positional, so only a trailing column may be blank.
  **The user's hand-test then earned the slice its keep**, which is the whole argument for CLI-
  before-app: building out two real artifacts surfaced that `Matcher.relational` reads each
  co-mention's `PersonRole` as relative to *the mention being scored*, when a record's roles are all
  relative to its **subject**. Correct for the subject, wrong for everyone else — and it does not
  merely miss, it **penalizes**: the deceased's father drew a `spouseName: none 0` from comparing
  the *deceased's* wife against his own, scoring 18 points below the deceased on a *better* name
  match. Worst of all, recording the true marriage dropped the deceased 73 → 55, so a true
  conclusion made the matcher less confident about a correct pair — corroboration running backwards.
  Now **slice 45g**, scheduled before 45e. *Lesson: a dimension that scores `0` where it should have
  been `nil` is not a smaller error than a missing one — `nil` means "the record is silent" and `0`
  means "the record disagrees," and the roll-up believes the difference.*
  Two non-findings worth recording, both raised by the same hand-test and both **working as
  designed**: a married surname (`Gussie Feldberg` vs a person stored only as `Gussie Haskel`)
  scores 0 because `keysIntersect` requires *every* token of the shorter name to find a partner —
  the rule that stops `Marcus Hanner` keying to `Marcus Feldberg`, and the data-model answer already
  works (adding her married name took her 0 → 85). And `Pinchas Harnauk` → `Marcus Hanner` scores 0
  twice over: `Harnauk` keys apart from both `Hanner` and `Hanaur` *on its own*, and `Pinchas`→
  `Marcus` is the americanization blind spot `MatchKind.knownVariant` is reserved for.
  70 → 96 CLI tests, macOS and Linux; 426 engine tests unchanged.

- **Phase 3 slice 45g — the relational dimensions read `PersonRole` from the right vantage point.**
  A record is a **star around its centre, not a graph.** `PersonRole` states a role *in the
  document*, so a co-mention's role is relative to the record's **principals** — correct when
  scoring a principal, wrong for everyone else. Scoring a satellite, the only relation the document
  states is that mention's own tie to the principals, which is its role seen from the other end:
  `spouse` inverts to itself (so a widow's mention finally draws a `spouseName` from the deceased
  beside her), `parent` inverts to *child* — stated by the record, but scorable against nothing
  `PersonMatchView` carries, so unassessed. Every other pairing is **unstated**; inferring the
  sibling and in-law edges would invent relationships the record never asserted.
  **The principals are the mentions tagged `subject` — or, when a record names none, the mentions
  tagged `spouse`.** Shipped first as *the subject, or nothing*, which is what the spec said, and
  it was wrong: **neither marriage record in the corpus has a `subject`** (`{spouse: 2, parent: 4}`
  and `{spouse: 2}`), so the guard threw away the couple edge on the archive's strongest relational
  documents and cost four **confirmed-correct** links 4–9 points each — the slice's own failure
  mode, reproduced on the other record genre while its own regression tests stayed green. The spec
  had asserted the opposite ("its marriage register tags the groom `subject`") and nobody checked.
  Found by `/code-review` doing the one thing the suites can't: running the CLI over a copy of the
  real archive and diffing every confirmed link against `HEAD`.
  *Lesson: a fork settled on a claim about the corpus needs that claim **run**, not recalled —
  `{role: count}` over ten artifacts is a two-minute script and it would have changed the design
  before it was written.*
  **The root cause was an undocumented vocabulary.** `role` was a bare list of eleven strings in
  the spec with no statement of what any of them *means* relative to anything, so both the tagging
  and the reading of it were folklore. The spec (both copies) now says it: a role is read relative
  to the record's focus; a couple-centric record carries two `spouse`s and **no** `subject`, which
  asserts more than two `subject`s would (a census page is two subjects; a marriage register is a
  couple); and which party an unattributed satellite belongs to is **not expressed**, so a consumer
  must not infer it. That last clause is the honest description of the best-of parent read — a
  workaround for a missing edge, logged as a candidate **within-record relationships** slice, whose
  couple edge is symmetric `spouse`-on-both-ends rather than GEDCOM's `HUSB`/`WIFE`.
  **`MentionMatchView` needed nothing new** — the focal `role` plus the co-mentions' roles already
  expressed the vantage point, which is why this stayed inside `Matcher`.
  **The gotcha: the three observed failures were not one bug.** (1) the widow's missing dimension
  and (2) the father's spurious `spouseName: none 0` are the vantage point. **(3) survives it** —
  the deceased *is* the subject, so the couple edge is genuinely stated from either vantage, and the
  73 → 55 drop came from `spouseName` going `nil` → `0` when the recorded married name didn't key
  to the stored maiden name. Any star model keeps that edge and a zero always drags a weighted mean,
  so the spec's own regression test could not have passed on the specced change alone. Settled with
  the user *before* building: **relational evidence is positive-only — reported, never scored.**
  A disagreeing `spouseName` still appears in the breakdown (the reviewer wants the lead) and does
  not move the roll-up, because a name disagreement between two genuinely-married people is the
  common case: maiden against married, Yiddish against Americanized, one clerk's transcription
  against another's. This is the standard record-linkage asymmetry (**Fellegi–Sunter**): a field's
  *disagreement* weight is governed by how often truly-matching pairs disagree on it, and for a name
  read across records that rate is high enough to make the penalty worthless. The fact dimensions
  keep their zeros because each justifies itself with a conflict sentence; a relational zero
  explained nothing. `toolIdentifier` → `genealogic-matcher/2`; stored breakdowns keep their values
  by design (45c).
  **One line past the specced engine-only layer:** `match explain` marks a non-scoring relational
  dimension `(not scored)` — "show the 0" actively misleads beside a confidence figure if nothing
  says the 0 did nothing. The rule is *mirrored* in the CLI rather than imported, like `(not
  assessed)` before it, keeping 45d's no-`GeneaLogicMatch`-dependency bet intact.
  **Positive-only turned out to license the ambiguity too.** Several principals no longer void a
  record: whose parents are the four named on a marriage register is *unknown*, not *unstated*, so
  they are read best-of for either spouse — and an ambiguous read that misses now costs nothing,
  so discarding it buys no safety and loses the evidence the record exists to give. Same for two
  `subject`s (the corpus's 1950 census). The two rules compose: the vantage point decides what the
  record *states*, positive-only makes a generous reading of it *free*.
  *Lesson: a roll-up that is a weighted **mean** cannot express "observed and uninformative" —
  absent renormalizes away, zero drags. An additive log-odds model gets that distinction for free.
  Not worth reshaping the roll-up on one data point, but it is the reason the fix reads as a
  special case rather than as a weight.*
  Measured on a copy of the real archive: **all 14 confirmed links at their pre-slice scores, and
  the death certificate's two parent mentions 55 → 74 and 56 → 74.** 426 → 437 engine tests,
  96 → 97 CLI, macOS and Linux.

- **Phase 3 slice 45h — `county`/`country` were never match kinds.** `MatchKind` is closed, and
  spec §7's justification for closing a vocabulary is that it is **GeneaLogic's own domain**.
  `exact`/`phonetic`/`known-variant`/`within`/`none` pass that test — they describe how *this*
  matcher reached a verdict. `county`/`country` describe the world's administrative geography,
  which is neither GeneaLogic's nor exhaustible (gmina/powiat/województwo, 都道府県/市/区,
  vilayet/sanjak/kaza). So they were **misfiled, not a closed list that needed to grow** — the
  opposite diagnosis to 44h's `PersonRole`, and worth the contrast: *the test is domain, not
  convenience.* Place depth moves to a new open `MatchGranularity`, reported beside `kind: within`.
  **Known cases are structural — `specific`/`partial`/`coarse` — because that is what the code
  actually computes.** `PlaceMatching` splits a string on commas and counts which components line
  up; it holds no gazetteer and cannot tell a county from an oblast. Naming its output after
  administrative tiers claimed knowledge the code does not have, which is the whole error in
  miniature. Open, so a gazetteer-backed matcher can later say `parish` or `admin2` for real.
  **The gotcha, and a spec fork that didn't survive contact.** The plan said a stored `county`
  decodes to `within` + "the matching granularity". There is no matching granularity: `county` was
  emitted for *two* claims at two scores (town 80, province 55), so the mapping needs a score
  heuristic — and this repo's own golden fixture stores `county` at **50**, a score `PlaceMatching`
  never emitted, which broke it on the first test run. Settled by **keeping the word and changing
  only the field it lives in**: the retired kind decodes to `within` with the original string
  preserved as `.unknown("county")`, round-tripping verbatim thereafter. A stored breakdown is a
  verdict at a time (45c) — preserved, not re-derived — and `.unknown` is precisely "a value this
  version has no name for". Drops the decode-only asymmetry the plan proposed, so nothing is
  silently rewritten. *Lesson: when a migration needs a heuristic to recover meaning the old format
  didn't record, that is the format telling you the meaning was never there — relocate the value,
  don't reconstruct it.*
  `MatchDimension` decodes by hand solely for this; the one live consumer, `PlaceMatching`, and the
  CLI's gloss (`birthPlace  within  80  to specific`, printed verbatim so an unknown value still
  reaches the reader) were the rest of it. **The app needed no change — it names no `MatchKind`
  case**, which is what made a closed-vocabulary edit cheap. `toolIdentifier` unchanged: every score
  is byte-identical, and its own rule exempts a refactor that provably cannot move one — pinned by
  giving `DimensionScorerTests` exact integers (80/55/30) against that file's usual preference for
  relative assertions, because "representation-only" should be provable rather than asserted.
  Timing was the point: taken before 45e, the app triage inbox, because that slice is a link-
  *production* accelerator and this one's cost scales with links already on disk. The archive held
  14, **none of which stored a place dimension at all**.
  437 → 443 engine tests, 97 → 98 CLI, macOS and Linux.
- **Phase 3 slice 45e — the app triage inbox.** A fourth **Review** section (fork (a): a
  workspace you work through, not a sheet — the two sheet precedents are one-shot *reports*, and a
  modal queue would block reading the document while deciding), over one **additive engine entry
  point**: archive-wide `suggestLinks(minimumConfidence:limit:)`. Fork (b) took that deliberately
  past "app only" — looping the per-artifact direction rebuilds and re-projects the whole
  conclusions corpus once per artifact for the same answer. Grouped, in **document order**: a
  mention nothing scored has no confidence to sort on, so a ranked queue could not carry the
  *somebody-new* case at all. Fork (c) split 44i's deferred cross-person suggested-**facts** lane
  out to **45i**; fork (d) pulled the resolve sheet's in-place suggestions in.
  **A suggestion row resolves through `confirm`, the hand-picked list through `link()`** — not an
  inconsistency but the record staying honest: `link()`'s honest minimum is a claim that no matcher
  ran. Verified on disk both ways (a suggestion stored `name within 97, delta 3, spouse+parents
  exact, aggregate 91, createdBy machine`; somebody-new stored the human minimum).
  **Two things the hand-test changed.** The below-threshold mitigation used a **zero** floor, and
  everyone who resembles a name in no way whatsoever ties at zero — so the "closest existing
  people" list filled with whoever the uid tiebreak put first, dressing three strangers up as
  candidates in the exact step that exists to prevent a false suggestion. Floor is now **1**: a zero
  is not a faint resemblance but the absence of one, and "no one resembles this name, at any score"
  is the honest answer. And the accessory's expander **earned its removal** — a cramped row carrying
  two competing controls to show an accounting the Review pane already draws properly.
  **The gotcha: `.onAppear` on a view that renders nothing never fires.** The accessory held its own
  state and loaded in `.onAppear`, but its body was a `Group` that rendered nothing until candidates
  arrived — an empty `Group` collapses to `EmptyView`, a view never in the hierarchy never appears,
  and so it sat permanently empty while the matcher had a 91 to offer. No error, no warning, and it
  looks exactly like "nothing matched". Fixed by loading in the host, which always renders.
  *Lesson: self-contained state is worth less than a load that cannot deadlock against its own
  visibility.*
  **The specced local-list-patching was dropped as unnecessary.** Its stated purpose was to stop the
  queue reshuffling mid-pass, but document order is deterministic and a verdict on one pair moves
  nothing else — so the worklist recomputes at `refresh()`'s existing chokepoint (gated on the
  section having been opened, so a window that never visits Review never pays for a sweep). That
  also makes ⌘Z work for nothing: patching forward-only would have left undo showing a stale queue.
  Confirmed by hand — undo of confirm / reject / somebody-new each restore the row, and
  somebody-new's single ⌘Z removes the link *and* the minted person.
  The app enables `MemberImportVisibility`, under which 45b's `public import` re-export makes
  `ScoredMatch` *nameable* but not its members readable — four view files name `GeneaLogicMatch`
  explicitly (no new target dependency). 45d's rejected-only case verified in the UI: a mention whose
  only candidate was rejected stays in the queue and says so, rather than blaming the floor.
  **`/code-review` found four, all fixed here.** Two were the same mistake in different clothes —
  *trusting a display string, and trusting a query that filters*: the per-document sections were
  `ForEach`-identified by `Artifact.title`, a user-supplied string with nothing enforcing uniqueness
  (two untitled records suffice), and duplicate `ForEach` ids drop rows — a silent gap in the one list
  whose whole invariant is that an unresolved mention cannot go missing, looking exactly like the
  matcher having nothing to say. And the somebody-new sheet's "no one resembles this name at any
  score" is **false when the resembling person was rejected earlier**, because `suggestLinks` applies
  the skip rules at every floor — a wrong claim in the one step that exists to prevent minting a
  duplicate, about the very person the archive already held. It now names the rejection, the same
  distinction `noCandidateExplanation` and the CLI's `noCandidateLine` already drew.
  **Hand-testing then pulled two things in from "out of scope", both for the same reason — a
  statement the UI made that it then couldn't back.** The pane says confirming *stores exactly these
  numbers*, and nothing in the app ever showed a stored breakdown again: `genea match explain` was
  the only reader. The resolved-mention chip now has a **Why?** disclosure drawing the link's stored
  `MatchBreakdown` — deliberately **not** re-scored, because a breakdown is a verdict at a time and
  re-deriving it on render would quietly answer a different question than the reviewer was asked
  (that comparison is `matchScore`'s job, and it is an audit, not a display). A hand-made `link()`
  reads correctly there too: `not assessed` on four rows *is* the claim that no matcher ran.
  Likewise the queue said a candidate "was rejected earlier and isn't offered again" and then offered
  no way back — 45e had specced un-rejecting as CLI-only on the grounds that ⌘Z covers the immediate
  mistake, which it does, but not one made in an earlier session, and the queue is exactly where that
  is discovered. **Restore \<person\>** now sits under that sentence and in the somebody-new sheet,
  one button per tombstone, naming the person being withheld (each rejection is an independent
  verdict, so a bulk "restore all" would flatten the distinction). No engine call: a tombstone *is*
  an `EvidenceLink`, so it routes through `unlink` (45c's "no fourth verb").
  **Three narrow-container layout bugs, all from drawing a wide pane's view in a 250pt inspector:**
  `Phonetic` hyphenated to "Pho-netic", `via Daitch Mokotoff` broke to "Mokotof / f" (a keyer's name
  split across lines names no keyer), and the source weights split mid-label. Fixed by making the
  label/kind/score `fixedSize` — they are the row's meaning, and a broken word costs more than a
  wrapped tail — and giving the row a `ViewThatFits` fallback that drops the gloss to its own line;
  the weights row became a shared `SourceWeightsRow` (it had been hand-written twice) that stacks
  when narrow. The somebody-new sheet also lost its `ContentSheet` height floor when it has no
  candidates to list — three short paragraphs inside a 380pt floor is a centred island of margins —
  and its prominent Create button gained `.keyboardShortcut(.defaultAction)`: it *looked* like the
  default action without being one, so Return did nothing. Prominent styling is a promise about the
  keyboard as much as the eye. That sheet's candidates are now loaded by the host **before**
  presenting, because a `.fitted` sheet measures once at open — the same visibility-versus-load trap
  as the accessory bug above, in its layout form.
  Also: `links(forArtifact:)` decodes **every** link in the archive per call, so counting rejections
  eagerly made building the worklist O(artifacts × links) main-actor decodes on every mutation — to
  answer a question only candidate-less rows ask (2 of 20 here, none in a triaged archive), so it is a
  second pass over those rows. And `recordReview`'s catch omitted the `bumpAndRefresh()` that
  `resolveMention` and `createPersonAndLink` both do deliberately: the engine writes and indexes the
  new link *before* superseding the old verdict with no rollback (45d), so a throw leaves a durable
  link the queue would keep offering a decision about.
  443 → 449 engine tests, macOS and Linux; 98 CLI unchanged.
- **Phase 3 slice 45f — `mergePersons`, the one operation that cascades.** Two records for one
  person are an *expected* state (§4.1 leaves entity duplication to this layer), and 45e's
  *somebody new* mints them by design. Merge repoints instead of orphaning: the absorbed person
  was never a second person, so every link and relationship naming them is still true. **This is
  §2.3's one exception**, and it inverts the undo shape — no snapshot can reverse an N-record
  rewrite, so `mergePersons` returns a **`MergeDecision`** holding the before-state of everything
  it touched and `revertMerge(_:)` replays it. Pure restore, because **the merge mints nothing**:
  there is no uid to un-create, which is also what makes the revert idempotent.
  Four forks settled before any code. Detection split out to **45j** (person↔person scoring is a
  new entry point with its own roll-up question — `ScoredMatch`'s two GPS weights are meaningless
  between two conclusions). A **confirmation beats a rejection tombstone** when the merge puts both
  on one triple: the tombstone said *this mention is not that person*, and the merge is the later,
  more specific judgement. **Self-loops and duplicate edges are dropped** (a person married to
  themselves is something the tree would have to draw) with the collapsed edge's facts union'd into
  the survivor. And the **CLI shipped in the same slice** — this is the most destructive engine
  operation yet, and it wanted a scriptable, Linux-hand-testable path before a GUI touched it.
  **The rewrite includes rejection tombstones**, which is 45c's rule read the other way: *citation
  or record on disk*. Hidden from every citation surface, yes — but a tombstone left naming the
  absorbed uid dangles *and* stops foreclosing the pair it exists to foreclose.
  **The one place a citation is repaired rather than reported:** two confirmations on one triple
  assert the identical thing, so the collapsed one's `supportedByLinks` citations are repointed at
  the survivor. Every other drop reports its strands (`strandedCitations`), because a dropped
  tombstone is a *different* claim and repointing there would turn a recorded "no" into evidence.
  Small shared refactor: `decision(writing:superseding:)`'s stranded-citation sweep became
  `strandedCitations(naming:index:)`, since the review lifecycle and the cascade both remove links
  out from under citations and reporting one but not the other is the inconsistency.
  **`couple` compares unordered, everything else ordered** — §4.5's endpoints are symmetric for a
  couple and directional for parent-child, and an open-vocabulary type this build has never heard
  of gets the conservative reading rather than a guess about its symmetry.
  **The defect self-review caught: a merge cleaning up anomalies it never caused.** Both cleanups
  were written over *every* candidate record, so merging into a survivor who already had a
  duplicate parent-child edge (or a stray second verdict on one triple) silently deleted it —
  correct-looking, reported, revertible, and still wrong: it removes a record for reasons the user
  never asked about, inside one undo step labelled "merge". Now a drop requires that the record was
  one the merge actually moved. *The rule that generalizes: an operation may resolve the collisions
  it creates, and may not adopt the ones it finds.*
  **`/code-review` then found that fix had only been applied to half the cascade** — the
  relationship path got the guard, the link path didn't, so a stray second verdict the survivor
  already held was still deleted. What let it through is worth more than the fix: the test meant to
  cover it was **vacuous**, because `link()` *supersedes the pair itself* (45c), so calling it twice
  can't build the anomaly and the merge was never handed the collision. The fixture now restores the
  displaced link back onto disk the way a concurrent writer would, and **asserts its own setup** so
  it cannot silently go vacuous again. The rule is now stated once for both halves: what a merge
  creates is a collision *across* the two persons, so the losing **side** goes and duplicates within
  one side are left alone. That in turn exposed a third thing: with the losers no longer swept up
  wholesale, **every surviving link naming the absorbed person must be repointed**, not just the
  winning verdict — otherwise the absorbed side's own duplicate outlives the record it names, which
  is the dangle the whole operation exists to prevent.
  Also from review: both front ends reported relationships touched *only* to follow a citation onto
  a combined link as "repointed onto ⟨survivor⟩" — false of an edge between two bystanders. Split on
  the decision (`repointedRelationships` vs `citationFollowingRewrites`) rather than filtered at each
  call site, so the two reports can't drift.
  **The defect the hand-test caught: a fact is a claim plus its evidence, and the two halves merge
  differently.** Exact-equality union — right for names — read a differing `supportedByLinks` as a
  differing assertion, so two records each carrying "Birth 1881, Łomża" from their *own* source
  merged into two identical-looking rows. That is backwards: agreeing about a birth is what
  corroboration looks like, and it is the **normal** shape, because 42c stamps every
  recorded-from-evidence fact with the link it came from. `unionFacts` now folds on the claim
  (type/date/place/value) and unions the citations — one fact, two sources — while `1881` vs `1881~`
  stay two facts, since deciding *those* are one claim is a judgement about evidence, not
  bookkeeping. `planRelationships` was already doing exactly this for a collapsed duplicate edge;
  the same concept had two answers in one slice.
  **And the tie-break that was never one.** Both collapses kept "the older record, by lowest uid" —
  but this archive's `UUIDv7` is *deliberately* non-monotonic within a millisecond (its own doc says
  so), so two records minted in one pass sort by their **random** bits: which of the user's records
  survived was a coin flip, and the tests passed on luck. Now the **survivor's own** record is kept
  and the absorbed one folds into it — stable, and the answer that matches what was asked for, since
  the user named which person to keep. Both tests now create the absorbed person's record *first*,
  so a uid rule would fail them. *Lesson: "lowest uid" is only "oldest" at the resolution the
  generator guarantees, and this one guarantees milliseconds.*
  Local-tooling gotcha, not a code one: `.build-linux-GeneaLogicCLI` served a **stale
  `GeneaLogicArchive` module** and failed the Linux CLI build with "no member `mergePersons`" while
  the engine's own Linux run was green — `rm -rf` the per-package scratch dir when a path-dependency
  gains a file. 449 → 472 engine tests, 98 → 101 CLI, macOS and Linux. Hand-tested in the app:
  merge, the report, ⌘Z, ⌘⇧Z, and `genea verify` clean afterward.

- **Phase 3 slice 45i — the cross-person suggested-facts lane.** Promotable evidence was only
  visible on whichever person happened to be selected. Review now carries **two lanes in one
  sidebar** (fork (a)): unresolved names under their document, then persons under *Suggested Facts*.
  No mode switch — the lanes stay legible because they are different sections with different row
  shapes, and one selection space serves both via **lane-prefixed ids** (`ReviewSelection`); a stale
  `@SceneStorage` id just fails to resolve, which is the right outcome anyway.
  **A row is a person, not a suggestion** (fork (b)): their evidence is one act of judgement, and it
  puts the lane's pane and `PersonDetailView`'s own section side by side showing the same list.
  **The slice is the hoist, not the view.** `loadLinkedEvidence` / `isAlreadyRecorded` /
  `recordSuggestion` were private view code with one reader; a second reader is where two answers to
  one question start to drift, and the drift would be *silent* — nothing in the UI says which surface
  is right. They now live in `SuggestedFacts` (pure, no `Archive`) with `ArchiveModel` supplying the
  two call sites. Including `recordedFacts(of:relationships:)`, whose couple-facts half is the one
  easy to drop: a marriage rides the `Relationship`, not `Person.facts`, so a lane comparing against
  `person.facts` alone would re-offer every already-promoted marriage. Hand-tested on the pair the
  rule protects (a person whose marriage is recorded is absent from *both* surfaces).
  **The slice widened past "app only" for one accessor** (fork (c)): `links(for:)` decodes the whole
  link table per call, so a per-person sweep is O(persons × all-links) main-actor decodes on every
  mutation — the shape 45e rejected for the same reason. Added `Archive.links(includeRejected:)`,
  which inherits its siblings' default-hiding rule; it is a **third citation surface**, so it got
  45c's audit test rather than being trusted to be too small to matter. 472 → 474 engine tests,
  471 on Linux; CLI untouched.
  **The defect `/code-review` caught, and why moving code found it:** a **recorded age could never
  be deduped**. The comparison demanded the promoted fact carry the suggestion's values verbatim,
  but §2.3 forbids deriving the year *for* the user, so applying an age means typing a date the
  evidence doesn't state and the match can never succeed. Harmless as a lingering row on one
  person's pane; fatal to an **inbox**, which could never reach empty — the same code, relocated,
  changed how wrong it was. *The rule: the comparison must match what the path can actually
  produce.* A recorded fact can be affirmed verbatim, so it is compared verbatim (an edited apply
  deliberately still shows — the evidence wasn't recorded as-is); an age can only be transformed,
  so it is discharged by **link + type**. Also: `recordSuggestedFact` went from private-beside-its-
  caller to model API with two callers, where the button's own condition stops being the guarantee
  — `isDirectlyRecordable` is now a `guard` + `assertionFailure` rather than a comment, so a future
  miswiring can't quietly write a couple fact into `Person.facts` (§4.5).

- **Phase 3 slice 45j — the person↔person scorer.** Finding two records for one human being
  was eyeballing the People list. `DuplicateMatcher` + `Archive.duplicateCandidates()` +
  `genea person duplicates [--explain]`; no format change.
  **The fork was settled before any code, and it resized the slice.** *Not a duplicate* needs
  memory, and the options were a stored record (a format change) or session-only dismissal.
  **Stored wins**, because the lane lands in a Review section that counts work owed and has a
  "Nothing to Review" empty state — two genuinely distinct same-named relatives would hold it
  permanently non-empty. Settled **on principle rather than on the corpus**: the real archive is a
  subset of the archive it will become, and the app is not only for its author's family. The
  record can't be an `EvidenceLink` (no mention) and must not be a `Relationship` with an open
  type — *not the same person* is an identity assertion, not a family relation, and every
  consumer of `relationships()` would have to filter it (45h's misfiling, again). That record
  is a slice: **45m** ships it with the lane; 45l's fork (b) now points there.
  **`DuplicateScore` is a separate type from `ScoredMatch` because neither side is a source.**
  The two GPS weights have nothing to weigh, and any value written into them would be a lie —
  so they are absent, and the roll-up loses its source-discount stage with **nothing replacing
  it**. The corroboration factor carries that load alone and bites harder for it (uncorroborated
  retains `0.75`, not the link scorer's `0.88`): the action on offer is a destructive merge, not
  a row in a queue. `MatchBreakdown` itself *is* reused — its fields are already the symmetric
  set — so no surface that draws a breakdown had to fork.
  **The floor is anchored on the blind spot, not picked round.** Names agreeing on nothing at
  all, corroborated three ways, land at exactly 50 — admitted, bottom of the queue: that is the
  `Zelig`/`Sidney` known-variant case the name matcher cannot see. Exact-name-only is 75, a
  weak-phonetic-only pair 45, and an exact-name pair with a birth-year conflict **21** — so the
  grandson named for his grandfather drops out on the conflict penalty rather than needing a
  rule. Those five integers are pinned as tests, because a doc comment quoting a band the code
  doesn't produce is worse than no doc comment.
  **Death is a conflict, not a dimension** — `MatchBreakdown` has no death field and adding one
  is a format change, and two different recorded deaths are a sentence a reviewer acts on anyway.
  **The hand-test's useful half was the minted duplicate, not the clean pass.** The real archive
  surfaces **nothing** at the default floor or at 25 (one pair at 15 with `--min-confidence 1`,
  correctly), which is the specced expectation but proves only precision. Minting a duplicate
  Sidney Feldberg put it at **83** — the documented exact-name-plus-one-corroboration band, on
  real records — and merging it away removed it, archive verifying clean.
  *The gotcha, and it is not this slice's code:* the sole corroboration in that 83 was
  `birthPlace exact 100` for two people both recorded as born in **"Poland"**. `PlaceMatching`
  scores its `countryScore` 30 only for *partial* agreement; two identical single-component
  strings are `exact`. Country-level agreement therefore reads as a perfect place match, which
  matters more here than on the link side precisely because corroboration is carrying the
  discount's job too. **Fixed in 45n** (next entry), which took that 83 down to 68 and the
  archive's one false pair from 15 to 7.

- **Phase 3 slice 45n — an unqualified place agreement claimed a depth it couldn't know.**
  `PlaceMatching` compared component arrays for equality **before** any granularity
  reasoning, so two bare `"Poland"` birth places scored `exact / 100` — a perfect match and
  full corroboration — while the file's own `coarse = 30` ("Two people born in Poland is
  barely evidence") was reachable only when the strings *differed*. Raised by 45j's
  hand-test, taken **ahead of 45k** on 45h's reasoning: it changes what new links store, and
  that gets dearer with every link confirmed.
  **Neither existing reading was right, and that is the whole entry.** 100 asserts the
  agreement is maximally specific; 30 asserts it is minimally specific. The matcher holds
  **no gazetteer**: `Poland`/`Poland` and `Łomża`/`Łomża` are indistinguishable to it, and
  one is barely evidence while the other is strong. Resolving that ambiguity in *either*
  direction repeats 45h's mistake — the one that put `county`/`country` in a closed
  vocabulary — just pointing the other way.
  So `kind` **stays `.exact`** (the values genuinely are equal; `.within` means *close
  enough but not equal*, and claiming a difference that isn't there is the same lie as
  reporting a keyer-missed name as `.phonetic`), with a new open `MatchGranularity` case
  **`unqualified`** and a score of **50**. The number is chosen against exactly one line:
  it sits between `coarse` and `specific` and lands **below the corroboration threshold of
  60**. *The invariant: uncertainty must never manufacture confidence* — the same asymmetry
  that makes relational evidence positive-only and keeps conflicts out of the mean. It
  still moves the weighted mean; it just stops counting as breadth.
  **This is the first `kind: exact` to carry a granularity**, which the spec had forbidden
  in words ("absent on an exact match, where there is no partial depth to report"). That
  sentence *was* the bug restated. Both copies updated; open vocab, additive, no schema
  bump, and a pre-45n breakdown keeps what it stored (45c: a breakdown is a verdict at a
  time, not something a later build re-scores on read).
  **The hand-test was the point, and it is 45g's lesson a second time.** All **14 confirmed
  links** in a copy of the real archive re-measured: three fell 80 → **70** — the three
  whose only corroboration was a bare-country place — and eleven were untouched. All 14
  stayed above the floor, and every affected mention still ranks its correct person
  **first**, by a wider margin than before (70 vs 7). The minted duplicate from 45j went
  83 → **68**, still found; the false Sidney/Gussie pair went 15 → **7**. Signal kept,
  noise halved.
  *The near-miss worth recording:* the pinned 45j bands (75/83/100/21/50) did **not** move,
  because every fixture behind them uses multi-component places — which is what made them
  a usable tripwire for "did this change reach further than intended?" rather than a chore
  to update.
  **`/code-review` then caught what the hand-test couldn't: `Matcher.toolIdentifier` was
  still `/2`.** 45n moves scores, and that constant's whole contract is to bump when old
  and new breakdowns stop being comparable — so a link written either side of the change
  was indistinguishable, and `match explain`'s stored-vs-today divergence (three links
  80→70) could not be attributed to the scoring change rather than to edited data. Now
  `genealogic-matcher/3`. *A behavioral change verified against real data still needs the
  audit trail that says which build produced it.*
  **The review's severest finding was accepted rather than fixed**, which is the other
  record here. An `unqualified` equality (50) ranks **below** a `specific` partial match
  (80): two bare `Łomża`s score under `Łomża`/`Łomża, Poland`. Read as "agreement", that
  inverts; read as what the dimension actually measures — *how far down* two places agreed
  — it is correct, because the second pair's `Poland` proves `Łomża` sits below the country
  level and the first pair proves nothing about either value. The genuine cost is that a
  bare-town archive now gets **no place corroboration at all**; that is the honest position
  without a gazetteer, and **45o** removes it by mining the archive's own place strings.
  The ladder is pinned as an ordering test and stated in both spec copies, since an
  argued-but-unwritten ordering is one that drifts.

- **Phase 3 slice 45o — place specificity from the archive's own places.** 45n's accepted
  cost, removed: a bare `Rypin` agreement now corroborates, because the archive writes
  `Rypin, Poland` somewhere and has thereby proved `Rypin` is not a country. No
  gazetteer, no format change — **the archive testifying about itself.**
  **The rule is *leading component of a multi-component string*, and the real corpus is
  what chose it.** The roadmap specced "any non-final component"; that promotes the `NY`
  in `Brooklyn, NY, USA` to town strength, which is 45n's overclaim wearing a different
  hat. The mirror rule — leading and never seen with anything below it — instead rejects
  `Brooklyn`, disqualified by a *street address* sitting under it. Leading-and-not-alone
  proves both halves at once: something coarser above, and some record naming it as the
  finest level it knew. *Three candidate rules, and only the corpus separates them.*
  **`/code-review` then caught the sentence above overclaiming**, and the correction is the
  entry's most useful line. The rule does *not* prove a value is a town — it proves the
  value is not top-level and that some record treated it as its finest level. An archive
  writing `Massachusetts, USA` promotes `Massachusetts`; `NY` escapes here only because
  this corpus writes `Brooklyn, NY, USA` and never `NY, USA`. That is a property of the
  **data**, and it had been written down as a property of the **rule**. Accepted rather
  than tightened, on a measurement: `Massachusetts` vs `Massachusetts, USA` has scored
  **80/`specific`** since 45h's leading-component branch, so promoting the both-bare case
  to 80 makes it agree with an answer the scorer already gave rather than inventing a new
  one. Every available tightening fails the motivating case — three components kills
  `Rypin, Poland`, "never seen lower" kills `Brooklyn` — and separating a town from a
  state is exactly the knowledge the parked gazetteer would supply. *Pinned as a test, so
  the equivalence the argument rests on is asserted rather than recalled.*
  **The design decision is that the vocabulary must be identical on every entry point**,
  and it is a correctness constraint, not a performance one: the explain path justifies a
  row the queue produced, and `confirm(match: nil)` **writes** a recomputed breakdown, so
  two differently-built vocabularies mean a stored score the user never saw. That is what
  forced the index `place` projection (schema **v3**, auto-rebuild on open) — gathering
  places from the records would have made `matchScore`, `confirm` and
  `duplicateCandidates` each decode every artifact under the lock to answer a question
  about two. *The projection stores **raw strings**, never the derived judgment*: put the
  promotion rule in the cache and changing it silently needs a rebuild to take effect.
  **Undefaulted on purpose:** `Matcher.score`/`DuplicateMatcher.score` take the vocabulary
  with no default, so a new call site must decide rather than inherit an empty one and
  quietly disagree with every other path. `PlaceMatching.score` keeps a default, which is
  what lets 45n's whole dimension suite stand unchanged as the *nothing-proved* baseline.
  `toolIdentifier` → `genealogic-matcher/4` (scores move; 45n's lesson applied without
  needing the review to catch it).
  *The gotcha is what the tripwire found — nothing.* On the real archive this slice
  changes **no score at all**: its four bare values are `Poland`, `Russia`, `New York`,
  `NY`, and not one of them leads a qualified string anywhere in the corpus. The rule
  fires on records not yet catalogued. A slice whose hand-test is "prove all 14 confirmed
  links are byte-identical" needs its actual behavior demonstrated on a constructed case,
  and saying so is the honest report.

- **Phase 3 slice 45k — within-record relationships.** The evidence layer can finally say
  *who is whose*: an additive artifact-level `mentionRelationships` array of
  `(type, person1Ref, person2Ref)` over the record's own `localRef`s. `PersonRole` is
  untouched and answers the other question (informant, witness, registrar); the direction
  is §4.5's, so `person1Ref` is the parent on both sides of the wall.
  **The matcher prefers a stated edge *per relation type*, not per record** — the one
  judgment call the fork left open, and the reasoning is that a register stating its four
  parent edges has not thereby denied that its two `spouse` mentions are a couple. Reading
  a record's silence as denial would mean **adding information to a record loses a
  dimension it used to score**, which punishes exactly the user who did the work. Silence
  *within* a stated relation is still a statement: a mention the parent edges don't reach
  goes unassessed rather than falling back to best-of-four. An edge-less record scores
  byte-identically, pinned as its own test. `toolIdentifier` → `genealogic-matcher/5`.
  **`Artifact` codes by hand now**, and that is the load-bearing detail: a synthesized
  decode requires every non-optional key, so a new array on this record would have made
  every artifact ever written fail to *load*, not merely lose a field.
  *The gotcha came from the hand-test, not the suite:* **a `couple` is symmetric, so the
  reverse pair is the same entry** — remove a partner edge and re-add it from the other
  person's row and an `==` duplicate guard stores both, which is precisely the each-edge-
  twice state the artifact-level shape exists to prevent. Fixed as
  `statesSameRelationship(as:)` in the model (symmetric for `couple`, strict for
  `parent-child`, where swapped ends are a *contradiction*, not a duplicate) and written
  into the spec. Three tests and two callers later, the invariant is that
  "one edge is one entry" needs a comparison equality cannot make.
  The `localRef` trap lands a **third** time (44c, 45c, now here): an edge claims a ref as
  firmly as an `EvidenceLink` does, so `nextLocalRef` takes an undefaulted `statedIn:`.
  Reuse would have made a stranger somebody's parent, invisibly.
  **The hand-test's UI findings, and the one that was a design answer rather than a bug:**
  the sheet clipped once its height stopped being fixed (a sheet is bounded by its
  window — the form scrolls now, header and footer pinned), and the feature was reachable
  only by knowing that clicking a mention's name opened it (an **Add Relationship…**
  affordance beside Add Fact… now names it, while the sheet stays its one owner). The
  third — *"why am I entering the parents twice, they're already mentions?"* — was the
  feature working as designed and **failing to say so**: on a record with one `subject`
  the roles already answer, and both the matcher (fork c) and 45l's derivation fall back
  to them, so edges are only load-bearing where the centre is ambiguous. The section now
  says which kind of record you are on. *A capability that is optional in exactly the
  cases most users will meet first has to tell them, or it reads as a chore.*
  **The second hand-test round found the sheet's real defect, and it was mine to begin
  with:** `.presentationSizing(.fitted)` sizes a sheet **once at open and never regrows**
  — the reason every other form sheet here carries a height floor, which this one didn't.
  A Relationships section that grows with the record therefore clipped, and the fix is
  both halves: a floor for the common case, a scroll for past it (plus a trailing gutter,
  since the overlay scroll bar is drawn *over* the rows' trash buttons —
  `.contentMargins(…, for: .scrollContent)` left the content full-width and moved
  nothing; plain padding did it). The same round also **removed the already-related from
  the "state a relationship" menu** — offering them could only produce a disabled button,
  and it implied a second Sidney↔Gussie edge was a thing to add when the user wanted to
  *change* the one that existed — and **opened the section on Add**, which needed the
  placeholder-ref trick: an add mints its `localRef` inside the write, so staged edges
  name themselves by a placeholder and `rebinding(_:to:)` binds them the instant the ref
  exists. *Being able to say who someone is to the others on the page is most of why you
  add the second and third mention; making that a second trip through a second sheet was
  the wrong shape of work.*
  **`/code-review` found the rule scoped to the wrong thing, and two tests that couldn't
  have caught it.** The preference was keyed on *the record* stating an edge of a type
  rather than on **this mention** being placed in that relation, so the first stated edge
  switched the star inference off for everyone: on a half-catalogued register naming only
  the bride's parents, the **groom** dropped `parents .exact → nil`, 89 → 85 — adding
  information taking a match apart, the precise failure the same diff's doc comment and
  §6.1 sentence both claimed to prevent. Scoping it per mention also deletes the
  `nil`-vs-`[]` subtlety I had written a paragraph defending: there is no `[]` case, only
  "this mention has stated edges of this type" or "it doesn't." *A rule stated in the
  doc comment is not thereby the rule in the code, and the two read alike to the author.*
  The tests that should have caught it were **vacuous in both directions** — one asserted
  a `nil` that `inverse(.parent)` already produced without any edges, the other queried
  the groom's mention against the bride's person and got `nil` from the confidence floor.
  Both are now written against a *confusable candidate* (a "Fay Hanner" whose parents are
  the groom's) and verified by disabling `statedCoMentions` and watching them fail.
  **Also from the review:** a Reveal offered for an edge that lost *both* ends, which is
  drawn on no row at all (now answered `false` at reveal time, the
  `relationshipEndpoint` precedent); a comment insisting artifacts are never bulk-loaded
  directly above the line that bulk-loads them; and `relate add`/`remove` validating
  *inside* the mutate closure, so a rejected command still rewrote `record.json`, the
  index and the manifest. That last one is pinned by an mtime assertion, because the
  record's **content** is identical either way — which is exactly why it slipped through.

- **Phase 3 slice 45m — the dismissal record + the duplicates lane.** A declined suggestion
  now has somewhere to live: `conclusions/dismissals/<DSM-uid>.json` (spec §6.6) — a typed
  `subject` over two `PersonID`s, the breakdown that was declined when there was one, and
  no status field at all. **Three forks, settled before any code.**
  *(1) The subject is an open vocabulary*, and the reading that decided it is not "does
  GeneaLogic own this axis" — it does — but **what an unrecognized value costs**: open, it
  round-trips and suppresses nothing, so the pair is simply re-offered (the pre-45m
  behaviour); closed, an archive a later version wrote fails to **load**, which is 44h
  verbatim. The evidence that the set is not exhaustive is that it grew twice (45j's, then
  45l's) before it first shipped. This widened **§7 itself**, which had justified openness
  only by alignment with external standards — a sentence that did not cover this case.
  *(2) The breakdown is stored when there is one, and the field is optional*, because 45l's
  suggestions carry no score and synthesizing one would be a lie in the shape of a number.
  *(3) Deletion is the retraction* — a dismissal **is** the negative record, so a tombstone
  over a tombstone has nothing to mean; there is no fourth verb here either (45c).
  **Symmetry is per subject** and canonicalized on write: `same-person`/`couple` store the
  lower uid first, `parent-child` is directional, and an *unknown* subject is read as
  directional — assuming symmetry would silently collapse two distinct records. That rule
  is `declines(_:between:and:)`, written up front rather than after a hand-test, because
  45k had just paid for the same lesson.
  **The merge cascade's new half is the interesting one:** a dismissal the merge makes
  self-referential is the user overruling *their own earlier judgement*, so it is dropped
  and **reported in its own sentence** (`contradictedDismissals`, distinguished from a
  collapsed duplicate by naming both merged persons) in both front ends.
  **The lane took 45p's off-main half with it.** `Archive` is already `@unchecked Sendable`
  behind its lock, so the quadratic sweep is a detached read plus a progress row — no engine
  change, no new entry point — and 45p keeps only the candidate-blocking pre-filter. It is
  the app's first non-main-actor archive read, and the first write to skip `bumpAndRefresh`:
  a dismissal is read by nothing any pane draws, so re-running the whole match worklist to
  reflect it would be work for no observer.
  **One spec sentence did not survive contact:** the lane's Merge… was specced "via the
  existing `PersonPickerSheet` path", but the pair is already known — a picker over every
  person re-asks the question the row answered. The pane offers the two directions instead
  (neither record is "the original"; uids are minted, not derived).
  *The gotcha came from the hand-test again, on the real archive:* **merging from the lane
  left its own row behind**, and clicking Merge a second time threw `personNotFound` (the
  first merge had succeeded). `mergePersons` funnels through `bumpAndRefresh`, which
  refreshes the people list and both older lanes — and the duplicates lane, deliberately
  *not* wired into `refresh()` because it is quadratic, was refreshed by nothing. The
  invariant that was missing: **a duplicates row is the only Review row that can offer an
  operation which cannot succeed**, so anything changing the *set of persons* — merge,
  delete, create, and every one of their undos — has to invalidate it. It re-scans rather
  than dropping the row, because a merge moves every *other* pair's score too (the survivor
  absorbed a second record's names and facts); the row naming the absorbed person is
  additionally dropped **synchronously**, since the scan is async and would otherwise leave
  it clickable for its duration. `personNotFound` from a merge is now a benign notice, not a
  raw error — it means a stale row, which is the user's cue that the list moved, not a fault.
  **`/code-review` then found the off-main claim was only half true.** The sweep ran inside
  `withIndex`, so a background scan held `Archive`'s single `NSLock` for all `n(n−1)/2`
  comparisons and every other archive read — on any thread, including the main one — queued
  behind it: the freeze *relocated*, not removed. The fix is the split the shape always
  wanted: `duplicateScanInput()` reads under the lock (linear, the same cost the other lanes
  pay) and `Archive.duplicateCandidates(in:)` is **pure**, so the quadratic half holds
  nothing. Pinned by a test that the two paths agree exactly. *Moving a call off the main
  actor does nothing if the lock comes with it.* The review's three smaller findings: the
  **redo** halves of merge and delete skipped the synchronous row-drop their direct
  counterparts do; `--subject` parsed leniently into `.unknown`, so a typo wrote a record
  that suppressed nothing and exited 0 (**open on the way in, closed on the way out** — the
  format must read a later version's subject, but minting one this build cannot consume is
  always a typo); and `dismissDuplicate` registered an undo even when `dismiss` returned a
  *pre-existing* record, so ⌘Z would have deleted a judgement it never made.

- **Phase 3 slice 45l — suggested relationships from the record.** The mini-phase's original
  gap, closed: a record that says who is whose now *proposes* it. Two readings in strict
  order — a stated `mentionRelationships` edge (45k) read **verbatim**, else 45g's star rule —
  and no format change; a promoted edge is a `Relationship` citing the links it came from.
  **The one thing the spec called "the same rule as the matcher's" is only two-thirds the
  same, and the third is the decision worth recording.** Stated edges genuinely are identical
  (there is nothing to interpret), and the record's *centre* is now literally the matcher's
  (`Matcher.principalRole(among:)`, one implementation, two callers). But the matcher's
  relational dimensions are **positive-only** — reading a marriage register's four parents
  best-of costs a wrong guess nothing, because a wrong guess merely fails to corroborate.
  A *conclusion* drawn from that same guess asserts that this bride's mother is that groom's.
  So the inference concludes only where the centre resolves to **one** person, plus the one
  two-principal shape that is still unambiguous (two `spouse` mentions are each other's
  partner). **Positive-only evidence and a written conclusion cannot share a tolerance for
  ambiguity**, even when they share a reading.
  **A suggestion is one row per pair-and-type, however many records support it**, citing all
  of them — two documents naming the same father are one conclusion with two citations, not
  two rows proposing it twice. That is also why the artifact inspector's half is a **filter
  over the whole-archive derivation** rather than a scan of one record: a per-record scan
  could offer an edge the lane considers settled, and nothing on screen would say which
  surface was right.
  **The lane is the first with no confidence figure, and that is the honest rendering.** Both
  endpoints were identified by a human, so nothing was scored; the reasoning §4.6 demands is
  therefore the citation itself — which record, and *stated* vs. *implied by roles*. 45m's
  optional breakdown field earns its keep on the decline path for the same reason.
  Symmetry gained a single owner while doing it — `RelationshipType.isSymmetric`, read by
  `MentionRelationship.statesSameRelationship` too, since a third copy of a rule about
  symmetry is where the two halves of a symmetric pair start to disagree.
  *The hand-test carried the calibration:* a copy of the real archive proposes exactly the
  two edges the slice was scheduled for (Szlama and Tauba as Sidney's parents) and nothing else
  across the other 19 records — the seven relationships already on file are subtracted. *The
  gotcha it also caught was pure UI:* the lane's chosen SF Symbol does not exist, so every row
  rendered with an invisible icon holding open an indent nothing filled. **A missing SF Symbol
  fails silently and takes its layout space with it** — the row still looked plausible.
  **`/code-review` found the ambiguity guard was scoped by the wrong thing.** It fired at
  *exactly two* `spouse` principals, so a **half-catalogued** register — bride entered, groom
  not yet, both fathers entered — fell through to the single-centre path and handed the bride
  every parent on the page, including the groom's father. The refusal was reached from the
  more complete record and missed by the less complete one, and the wrong edge would have
  appeared and then silently vanished as cataloguing continued. The guard now keys on the
  **kind** of centre: a `spouse` centre *is* a couple document, whose parents are unassignable
  however many parties have been entered. **A head-count is not an ambiguity test** — partial
  data is the normal state of a record being catalogued, and a guard that relaxes as data goes
  missing is inverted.
  **Hand-testing then widened fork (a) by one surface and rewrote the evidence layer's
  wording.** The person pane pairs Facts with Suggested Facts and had Relationships standing
  alone, which reads as *nothing here to promote* — false for exactly the person the slice
  was built for. `suggestedRelationships(for:)` is the same filter a third way, and rows
  there speak from that person's side (*Their child: Abram Feldberg*) rather than repeating
  the page's own title. And the mention editor read `[Parent ▾] of this person: [Name ▾]`,
  where the colon left the noun phrase free to attach either way — a cataloguer could take it
  as the **opposite** edge. It is now a sentence, `This person's [parent ▾] is [Name ▾]`, with
  the rows possessive (*Their parent: …*); the phrasing moved into one owner
  (`MentionRelationship+Display`), since it had been open-coded twice and both copies were
  ambiguous in the same way. **A label naming a relation must carry its direction** — §4.5
  fixes it on disk, and a UI that drops it hands the reader a coin to flip. Layout footnote:
  the composer is a sentence, so only the *name* picker may compress; with `.fixedSize()` on
  every element it wrapped mid-clause at the sheet's minimum width.
  Its other two: both single-line surfaces (the lane row, the inspector row) read the
  **archive-wide** `isStated` beside *one particular* document's title, so a suggestion
  implied by record A and stated by record B told the reader that A states it. **A title and a
  basis have to come from the same citation or neither** — the detail pane, which lists every
  citation with its own basis, never had the bug. And `confirm` minted a second identical
  `Relationship` where `dismiss` was deliberately idempotent; it now returns the existing
  record, with the app checking `asserts(_:between:and:)` first so ⌘Z can't delete a
  conclusion the click didn't make (45m's trap, on the positive side this time).

- **Phase 3 slice 46 — the source-tier vocabulary gap.** Two cases added to the open
  `SourceAuthorityTier` — `government` (80) for civil records that aren't vital registration,
  `monument` (60) for a stone — because the largest genre in an American-immigrant corpus had
  nowhere to land but `compiled`. No migration and no schema bump: the vocabulary is open, so
  an archive already carrying `"government"` as `.unknown` starts decoding it as a known case
  and re-encodes the identical string. `Matcher.toolIdentifier` → `genealogic-matcher/6`, its
  standing rule — re-weighting a tier makes old breakdowns non-comparable.
  **The invariant the gap violated: a tier a cataloguer would reach for as a fallback must
  score above saying nothing.** `compiled` is 25 against an untiered 40, and it asserts
  *"somebody's conclusion, not evidence"* — so tagging a naturalization certificate honestly
  scored it **below** leaving it blank, and 12 of the real archive's 20 artifacts sat there.
  That comparison is now a test; it is the one that would have caught this at the start.
  **The tier stays deliberately coarse, and the counter-argument is what shows why.** A draft
  card's weakness is not its genre but that its birth year is the registrant's *recollection* —
  a claim about a **fact**, which `informationQuality: .secondary` on that one `RecordedFact`
  already makes, and makes better. Whatever fits neither bucket keeps to `.unknown` on
  purpose; a tier per genre is how three orthogonal axes start re-encoding each other.
  **The hand-test found that "coarse" needs a stated *reading*, or it decides cases by
  accident.** The fork listed immigration and military among the genres left to `.unknown`
  while the problem statement counted them in the gap, and the archive's arrival manifest
  duly sat on `compiled` through a retagging pass that moved everything else — the worst
  square available, since `compiled` (25) scores *below* the unstated `.unknown` (40) it
  would otherwise have had. The definition settles it: **`government` is read by who created
  the record, not by the errand it served**, so a passenger list retained by the receiving
  authority is one however commercial the ship. Now in both spec copies. **A coarse
  vocabulary needs its boundaries written down more than a fine one does** — with few
  buckets, most of the work is in the reading, and a reading that lives only in a fork is
  one the next cataloguer re-derives. No code, weight or vocabulary changed.
  **It is a records-honesty slice, not a recall slice.** Retagging 45d's weakest true positive
  moves it 74 → 77, and even the `vital` ceiling reaches 86, because the roll-up bounds the
  source discount to `0.6...1.0` so a good source cannot invent an agreement that isn't there.
  If it is ever argued for on *scoring* grounds, that is the signal it has been mis-scoped.
  *Gotcha, small but exact:* the open-vocabulary test's sample unknown was `"probate"` — a
  court record, which this slice's `government` now covers. A sample chosen as "a plausible
  genre we haven't got yet" is a test scheduled to fail; it moved to `"shipManifest"`, the
  value 46 decided *stays* unknown, so the sample now encodes the fork instead of outliving it.
  **`/code-review` found the "no migration" claim is true of storage and false of *search*.**
  Promotion moves only the **query** side: a pre-46 archive holds `"Government"` as
  `.unknown("Government")`, `parsingLeniently` now folds a query for it to `.government`, and
  `find --source-tier Government` stopped returning the record. The control is what pins the
  cause — an *unpromoted* term with identical casing matched throughout, so it was never the
  casing. Fixed with `OpenVocabulary.denotesSameTerm(as:)`, folding **both** sides at the one
  comparison site; storage stays verbatim, and two `.unknown`s differing only in case still
  don't match, because that was already true and widening it would be a change, not a repair.
  **The invariant: promoting a case is not behaviour-neutral for anything that compares by
  `==`** — the vocabulary gains a case, and every stored spelling of it becomes a near-miss.
  **What the slice did *not* close, and the record should not imply it did.** `genea add`
  defaults `--source-tier` to `compiled` and the app's `ingest(_:)` stamps `.compiled` on
  every imported file unconditionally — so the 12-of-20 population 46 was written to explain
  is **generated**, not mis-tagged by hand, and regenerates on the next import. Both fail 46's
  own new test. The honest fix is to make `sourceAuthorityTier` **optional**, so it follows the
  rule its own sibling `sourceDerivation` already documents — *absent means unstated, never a
  default good value* — and that is a **format change**, so it went to the roadmap as **46b**
  rather than into this slice.

- **Phase 3 slice 46b — `sourceAuthorityTier` asserts a tier nobody chose.** A **format
  change**: the field is optional, so *absent means unstated* — the rule its own sibling
  `sourceDerivation` had documented and enforced since 44h, while this field violated it by
  being required. No schema bump; an archive written before today carries the key and keeps
  it, and nothing is migrated, because a stored `compiled` may be deliberate and a sweep
  cannot tell the two apart.
  **The invariant, and why 46 alone could not deliver it: a required field with no honest
  value forces every entry point to lie.** `genea add` defaulted to `compiled`, the app
  stamped `.compiled` on every import — so a document nobody had characterised asserted
  *"somebody's conclusion, not evidence"* about itself and scored 25, below the 40 that
  saying nothing earns. 46 shipped the vocabulary the gap needed; this removed the mechanism
  that had been *generating* it. The three asserting entry points all stop, and `set-meta`
  gained `--clear-source-tier`, because **a settable field that cannot be cleared makes
  *unstated* a one-way door** — the pattern `--source-derivation` already had.
  **Absence had to be given somewhere to live, or it is just a silent gap.** The sidebar
  banner reports the count and filters to exactly those artifacts, and the row says
  "no source tier" instead of quietly omitting it — **in the tier's own slot**
  (`no source tier · image`, beside `government · image`), not tacked on the end. It first
  shipped tacked on, which gave the *same field in two states* a different order, separator
  and font size; only the colour should vary. Caught by eye in the visual pass, which is the
  class of thing no test asserts. *The bug that shape invites, and the
  fix that only looked like one:* tagging the last uncatalogued artifact hides the banner —
  and with it the only control that turns the filter off — leaving an empty list and no way
  back. Guarding the *derived list* on `count > 0` makes that symptom vanish while leaving
  the filter **suspended rather than released**, so the sidebar silently re-collapses on the
  next import; `/code-review` found that the comment claiming the filter released itself was
  the only part that had been fixed. It now resets the state in `onChange` and keeps the
  guard solely to avoid an empty frame. **Masking a symptom in a derived value is not
  clearing the state that caused it** — and a comment asserting the stronger claim is worse
  than none, because it stops the next reader looking. **A work-owed view has to reach empty
  and survive doing so**; 45m learned this on the duplicates lane, and the smaller the
  surface, the easier it is to forget.
  **The schema version was deliberately *not* bumped, and that is a judgement with a cost.**
  This is the first change that is **subtractive** for an older reader — 44i, 45k and 45m all
  added optional keys, which an old build ignores, whereas a record written with no
  `sourceAuthorityTier` hits `keyNotFound` in any pre-46b decoder. `Migration` would have
  turned that into its purpose-built `unknownNewerVersion` error at open. It was left alone
  because a bump makes an old build refuse the **whole archive** even when every artifact
  still has a tier, and the archive currently has one user who always runs the latest build —
  so the cheap failure is the rarer one. *Revisit the moment a second reader exists*: the
  argument is about who is reading, not about the format.
  *The lookup decision worth recording:* an uncatalogued artifact matches **no** tier query.
  The alternative — absence matching anything — makes `--source-tier vital` quietly widen as
  the archive grows *less* complete, which is the opposite of what a facet is for.

- **Phase 3 slice 45p — the quadratic duplicate pass, made cheap.** Shipped, but **not** as
  the candidate pre-filter it was specced as, because that cannot be built soundly for this
  scorer. Two independent reasons: a key gate makes the name dimension's `.within` band
  unreachable (`Fay`/`Faye` are one woman and key apart — the ground 45b already rejected
  blocking on), and, decisively, `defaultMinimumDuplicateConfidence` is **calibrated on a
  pair whose names agree on nothing** and which is corroborated three ways. A name-keyed
  gate drops precisely the pair the floor was chosen to admit.
  **The invariant: an optimization whose correctness rests on an unchecked invariant is a
  worse trade in a recall surface than a slower scan.** The failure mode is an invisible
  false negative in the one surface whose whole job is to not miss a duplicate — nothing
  appears, and nothing says anything is missing.
  **So the cost came out of the comparison rather than the candidate set, and profiling
  said where.** In release, ~60µs of a ~92µs pair was Daitch–Mokotoff keying: a pure
  function of a string, recomputed once per comparison each token appeared in. Memoizing it
  makes keying `O(distinct name tokens)` instead of `O(pairs)` — **~92µs → ~15µs, 6×
  measured** — and, being the same function on the same input, it provably changes no
  result. 45b's standing condition for blocking ("if it is a superset it changes no
  results") is met by not filtering at all. 1,000 persons: 46s → 7s.
  *The measurement that reframed the slice was nearly not taken:* the first probe timed
  `addPerson`'s disk writes rather than the scan and showed nothing. **A quadratic-cost
  claim needs the cost measured at the thing that is quadratic**, not at the setup around
  it. The second probe, over the pure scorer, put 86% of the pair in name comparison and
  the bulk of that in keying — which is what turned "add blocking" into "stop recomputing".
  *The memo needed a lock, and the lock exposed a stale platform floor.* It was written with
  `NSLock` because the package declared `platforms: [.macOS(.v13)]`, below `Mutex`'s macOS 15
  — and **that floor turned out to be a manifest line, not a decision**: no doc stated it, no
  `@available` in the package exercised it, its own comment justified swift-crypto's macOS
  10.15 rather than 13, and the only Apple consumer is the app at macOS 26.5. It is now
  macOS 26 to match, and the memo is a `Mutex`, which lets `DaitchMokotoff` import no
  Foundation at all — **a correctness property for a phonetic keyer, not tidiness**, since
  Foundation's string APIs carry locale behaviour and a key that varied by locale would
  silently stop matching names it used to match.
  Two things the raise dragged with it, neither local to the manifest: `.v26` does not exist
  in PackageDescription 6.1, and raising `swift-tools-version` to reach it would make the
  manifest unreadable by the `swift:6.1` image **both** CI's Linux job and
  `scripts/linux-test.sh` run in — so the floor is spelled `.macOS("26.0")`. And CI's
  *package* job ran on `macos-15`, which cannot build a macOS 26 floor; it moved to
  `macos-26` beside the app job. **A platform floor reaches the manifest's own language
  version and every runner that compiles it.**
  **What remains is the real floor:** Jaro–Winkler over token pairs, inherently pairwise.
  Below it needs a gate bounding *string similarity* rather than phonetic equality — an
  ngram index, its own slice, still owing the superset proof. Parked with data.

- **Phase 3.5 slice 47 — two processes, one archive.** All seven design forks shipped
  together, no 47b needed: an archive-level `flock(2)` on `.index/lock` held for the whole
  mutation, a matching `busy_timeout` on every SQLite connection, a `.index/dirty` sentinel
  bracketing each mutation, and a re-read of `manifest.json` under the lock. Readers take
  none of it, deliberately — SQLite already gives committed-read consistency across
  processes, so a shared lock per lookup would make browsing contend with an agent's writes
  for nothing. The admitted consequence is stated rather than hidden: a read concurrent with
  a mutation may see the pre-mutation state — stale, never torn.
  **The invariant is structural, not per-call:** `Archive.withState` is now the mutation
  chokepoint for exclusion, staleness *and* divergence detection, the way it was already the
  chokepoint for index lockstep. Making it so required moving the three genuinely read-only
  callers (`verifyIntegrity`, both trash listings) to a new `withReadState` — they had been
  borrowing the mutation path for its `NSLock`, and left there they would have taken the
  cross-process lock and reintroduced exactly the reader contention fork (e) rejects.
  **The manifest re-read went one step past fork (g)**, which only specified mutations:
  `verifyIntegrity()` is the reader §10.5 names as the stale manifest's consumer, and its
  staleness was *unbounded* — loaded once at `open()` — where a reader's index staleness is
  bounded by one mutation. Different kind of stale, so it got the refresh too.
  **`.index/dirty` over-triggers on purpose.** It is left behind by *any* throw, including a
  pre-write `artifactNotFound` that cannot have diverged anything. The cost is one
  unnecessary rebuild on the next open; the alternative — classifying which errors wrote
  something — trades a cheap false positive for an undetectable false negative, which is the
  failure the sentinel exists to catch.
  *Gotchas that cost a round.* `ArchiveIndex.upsert` is **not one transaction**, so an
  injected index failure leaves the index *half*-applied (artifact row written, `place`
  projection missing) rather than untouched — the first version of the test asserted the
  artifact was absent and failed. A partial index is exactly as wrong and exactly as
  invisible to the three pre-existing rebuild triggers, which is the point. And finding the
  just-built `genea` from a test has **no single portable anchor**: on macOS the running
  executable is swift-testing's helper and the bundle path only appears in argv; on Linux
  `Bundle.main` is the test binary. Collect every plausible directory, pick the one that
  actually contains `genea`.
  ***/code-review* found three real bugs, and all three were in the *recovery* path — the
  part with no natural exercise.** (1) The dirty-sentinel rebuild reused the existing
  `removeItem(dbURL)` recovery, which is right for a corrupt database and wrong for a
  healthy one: another process's live connection keeps the unlinked inode, stops seeing
  new records, and its next mutation fails `readonly database` *after* writing the
  sidecar — the flock does not help, because a handle holds it only per-mutation, not for
  its lifetime. **A trigger added to an existing recovery path inherits that path's
  assumptions, and "the file is unusable" was one of them.** (2) `withState` cleared the
  sentinel unconditionally on success, so a later successful mutation erased an earlier
  failed one's marker and the divergence was never rebuilt — fork (f) defeated by its own
  cleanup. Fixed by never clearing a marker that was *already there on entry*, which also
  covers the cross-process case (a crashed writer's marker outliving a live handle's next
  success). (3) `create` ran its `alreadyExists` guard before the lockfile existed, so
  concurrent creates all passed it and the last silently overwrote the others'
  `archiveUID` — six of six "succeeded" on the old code.
  **Two of the three were invisible to the tests that already passed**, and the reason is
  worth keeping: every one of them needed a *second* event to show up — a success after a
  failure, a live handle during a recovery, a second create during the first. Single-shot
  tests cannot see any of that.
  **The concurrency tests were verified against the old behaviour, not just the new.**
  Reverting the lock and the busy timeout makes eight simultaneous `genea add` invocations
  exit 1 and lose writes; a concurrency test that passes either way is worthless. `flock`
  ownership belongs to the *open file description*, so two descriptors in one process
  contend exactly as two processes do — which is what makes the engine-side half unit-
  testable at all. Linux-verified: `flock`, `open(2)` and `strerror` all import cleanly from
  Glibc, and the multi-process tests pass in the container too.

- **Phase 3.5 slice 51 — the app notices another writer.** Reported as "deleting an
  artifact with `genea` changes nothing until I rebuild the index". **The diagnosis was
  most of the slice, and it inverted the request:** the engine was never stale — a
  long-lived handle sees another process's add *and* delete immediately — and
  `rebuildIndex()` was a no-op that happened to call `refresh()` afterwards. That call was
  the only thing doing any work. So the fix is a *trigger*, not a mechanism: one engine
  accessor, a 1s poll, and forty lines of app.
  **`PRAGMA data_version` is the whole protocol**, and it was chosen after measuring, not
  from the docs: stable across no-op reads, bumps on another connection's commit, and —
  decisively — provably *never* on your own, so the app can't mistake its own writes for
  someone else's and refresh twice per edit. It also catches a `person add`, which writes
  no `manifest.json`; the obvious cheap alternative, watching the manifest's mtime, would
  have missed conclusion-only writes entirely and looked like it worked.
  **Two specced requirements turned out to already be satisfied, and were dropped on
  evidence rather than built.** Selection survives because it lives in `@SceneStorage` as a
  raw id that the detail pane resolves at render time — so a surviving selection is kept
  and an externally-deleted one falls back to the placeholder, the same path a
  between-sessions deletion already took. And in-progress edits survive because every one
  of them is view-local `@State` that `refresh()` cannot reach: verified by typing into a
  title field through three external writes and watching it stay intact and focused.
  **A requirement you can demonstrate is already met is cheaper than one you implement.**
  ***/code-review*'s finding, and the invariant it restored:** the external path called
  `refresh()` where every local mutation calls `bumpAndRefresh()` — and `bumpAndRefresh` is
  documented as *"the single chokepoint every model-level write funnels through"*. Routing
  around it meant the browse lists updated but nothing keyed on `mutationVersion` did: both
  detail panes and the whole Tree tab. An external edit to the **selected** record stayed
  stale indefinitely and an externally asserted relationship never redrew the tree.
  **A second write path into a model has to satisfy the same postconditions as the first
  one, and the cheapest way to guarantee that is to call what the first one calls.** The
  duplicates lane needed its own invalidation for the same reason a local merge does — a
  row naming a person an agent deleted doesn't just show stale text, it offers a Merge that
  can only throw.
  **Then the category was retired rather than the instance fixed.** `refresh()` is now
  `private`, so `bumpAndRefresh()` is the only expression of "this archive changed" and the
  wrong call no longer compiles. Asking *what a test suite would have bought here* is what
  produced that: the answer was "less than deleting the choice", and reading the call sites
  to check turned up **a second, older instance** — `rebuildIndex()` had the same bug
  independently, and a rebuild is exactly when an open detail pane is most likely to be
  showing something the sidecars disagree with. **A doc comment calling something "the
  single chokepoint" is not a chokepoint; two call sites had bypassed this one.**
  *Two of the new tests were also vacuous*, and the shape is worth remembering: one read
  the change token *after* a competing mutation had already released its lock, so it would
  have passed even if the accessor took the lock; the other folded `nil` to a placeholder
  before checking for stability, so five failed reads counted as "stable". **A test whose
  assertion is satisfied by total failure of the thing under test is worse than no test.**
  Both now fail when sabotaged — verified, not assumed.
  *The split.* The specced fork (d) — mutations off the main actor, off 47's review — came
  out to 54 engine call sites and 17 `registerUndo` blocks in a 2,800-line `@MainActor`
  model with no shared chokepoint, against ~40 lines for everything else. Split to **52**
  rather than holding a working fix hostage to a refactor. The review also caught that the
  poll introduced a *new* main-actor cost at a cadence another process controls; that one
  is answered here rather than deferred, by scaling the next delay to what the last refresh
  actually took (capped at 15s), which bounds the work at roughly a tenth of the main actor
  however heavy the refresh.

- **52 — mutations off the main actor.**
  **The specced premise was wrong, and measuring is what showed it.** The slice said
  "no engine change — `Archive` is already `@unchecked Sendable`". Sendability was never
  the obstacle: `withState` took the process-local `NSLock` *before* waiting up to 5s on
  the flock, and **readers take that same lock**, so a blocked writer parked every read.
  Measured: one `artifacts()` call cost **1.82s** behind a competitor. Moving the write to
  a background thread would have relocated the freeze to the app's next read — 51's
  one-second poll guarantees one within a second — and the slice could not have met its own
  verification criterion. Re-ordered to `writerLock` → flock → state lock: **0.5ms**, and
  47's timeout and `archiveBusy` are untouched. **A concurrency fix that only moves work
  off a thread has to account for what that thread still needs to take.**
  *The undo trap the slice warned about, made concrete.* `NSUndoManager` files a
  registration by what it is doing **at the moment of the call** — so a counterpart
  registered after an `await` lands on the *undo* stack, not the redo stack, and ⌘Z becomes
  a one-way trip that redoes itself. Nothing throws. The rule is therefore **register the
  counterpart synchronously, then mutate**; five paths can't name theirs up front (the
  engine mints it — a fresh trash entry, a new `MergeDecision`, the removed record), so
  they register a promise and fill it in `commit`.
  *The app had no test target at all*, which is why this was invisible. Added one: 14
  undo/redo tests plus 4 that hold the lock from "another process". Both new suites were
  **verified by sabotage** — registering a counterpart late fails loudly, and the
  responsiveness test costs 4.91s for 50 reads without the engine change.
  **The gotcha that cost the round: the responsiveness test passed against the *broken*
  engine at first.** `mutate` hands off to a `Task`, which needs the main actor to start —
  so reads timed immediately after issuing a write measure a write that has not begun. It
  needed an `await` before the timing loop. Same family as 51's vacuous tests: *a
  concurrency test that never lets the thing under test start is satisfied by its total
  absence.*
  ***/code-review*, and the one lesson worth keeping.** Every finding was the same shape:
  **a caller outside the model that assumed the write was synchronous.** A chokepoint
  refactor changes a contract its call sites never mention, and the ones that break are the
  ones holding their own copy of engine state — two sheets reloading in the same turn as
  the mutation, and a window revoking its sandbox scope while a write was still parked.
  They now await a new `writesSettled()`. **When a slice makes something asynchronous, the
  audit is "who assumed it wasn't", and that is not answered by reading the file you
  changed.**
  *The grouping fix was worse than the bug, and only the hand-test could show it.* Two
  actions committing in one turn share a ⌘Z, so grouping was made explicit per-commit with
  `groupsByEvent` off — and renaming broke. **That manager is the window's, shared with
  AppKit's text-field undo**, so switching event grouping off changed typing's undo too: a
  second ⌘Z after a rename restored the typed text, reading exactly like a redo. Reverted;
  the merging case is now a documented limitation, and fixing it properly means a
  model-owned undo stack, which is a UI decision about what ⌘Z means inside a text field.
  **The lesson is about the test harness.** It had switched `groupsByEvent` off for
  determinism, so the model tests never had a text field attached to the manager and could
  not see the interaction at any point. *A harness that differs from production on a
  mechanism is not merely convenient — it is a blind spot with exactly that shape*, and
  the honest response is to say what it cannot cover rather than to widen it.
  *And the one only the app could show.* Undoing a rename twice did nothing the second
  time, with Edit ▸ Undo having lost its action name — the tell that a **nameless** step
  was on top. It was AppKit's: a focused `TextField` keeps a field editor that registers
  its own undo when the text is replaced programmatically, which the re-seed after an undo
  does. Synchronously that step landed inside `undo()` and became a redo; awaited, it
  arrives a turn later and lands on the undo stack. **Third instance of "a registration
  arrived a turn late", and the first where the registration wasn't ours** — the audit
  after making something async has to include the frameworks holding your views, not just
  your own call sites. Fixed by releasing focus when a re-seed overwrites the field the
  user is in. Untestable at this layer, and found only by driving the real window.
  *A predicted bug that wasn't.* The hand-test expected closing a window mid-write to lose
  it, and the first run seemed to confirm it — until the **control** (same edit, same
  contention, window left open) lost it too. Closing was never the variable; both runs
  outlived the 5s timeout. **A reproduction without a control is a coincidence with a
  narrative**, and this one would have bought a fix for a bug that does not exist. What is
  real is narrower: a write that fails after its window is gone has nowhere to show its
  alert.
  *One more:* the wait indicator fired on elapsed time alone, so a long *local* write
  blamed a competitor that didn't exist — the lock now reports real contention. The
  before-snapshot moved onto the write queue too, but with grouping reverted its symptom
  is unobservable, so it is kept as correctness rather than claimed as a fix.
  *And one finding that measurement retired.* The review suspected the new ordering let our
  reads starve another process. It doesn't (worst wait ~20µs under four unpaused readers);
  what starves a competitor is a tight write loop, **identically under both orderings**, so
  it is `flock` unfairness that predates the slice. The test written for it was **deleted
  rather than shipped flaky** — marginal at that granularity, and two-failures-in-three
  would have said less than the ROADMAP paragraph does.

- **54 — the Linux floor moves to Swift 6.3.**
  The `swift:6.1` image, not the Mac toolchain (6.3.3 for some time), was the real floor
  for both packages: every post-6.1 feature was gated on it, and it is why `platforms:`
  was spelled `.macOS("26.0")` rather than `.v26`. Bumped to `swift:6.3`, which *is*
  6.3.3 — the two platforms now match, and that string workaround is deleted along with
  the comment justifying it. Two commits on purpose (image, then
  `swift-tools-version`/`.v26`): the manifest change is unreadable by the old image, so
  the order is forced, and a green run exists for the bump alone. **This slice buys the
  option and deliberately does not spend it** — no 6.2+ API adopted, and strict memory
  safety is a decline rather than a defer, since `CSQLite` is wall-to-wall unsafe interop
  and would bury the signal.
  **The risk was a newer compiler *rejecting* code 6.1 accepted; it didn't** — 634 engine
  + 139 CLI tests pass on 6.3, and a from-scratch engine build emits **zero** warnings,
  vendored `sqlite3.c` included. Also re-checked the fact the whole `CSQLite` decision
  rests on: 6.3 still ships SQLite's runtime `.so` and still no `sqlite3.h`, so vendoring
  is as necessary as it was in the Phase 1b spike. Those notes in ARCHITECTURE §10 and the
  `CSQLite` README were reworded version-agnostically rather than re-pinned — *a rationale
  that names an image tag has to be re-edited every bump, which is how it goes stale.*

- **53 — the app joins the engine in Swift 6.**
  The app was in the weakest of the three positions: `SWIFT_VERSION = 5.0` with no strict
  concurrency, while `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` was on — paying every
  *cost* of the Swift 6 model and getting none of the *checking*, over code 52 had just
  moved off the main actor. Now `6.0` + `complete`, so all three components are checked
  the same way.
  **The spec's "free no-op checkpoint" did not exist.** Fork (a) measured
  `SWIFT_STRICT_CONCURRENCY=complete` under Swift 5 as building clean; it surfaces ~40
  warnings, which are precisely the Swift 6 errors demoted. Split into three commits
  instead of two — setting, fixes, mode flip — which is *better*, because the flip then
  really is verifiably nothing. **A measurement that says "this step is free" is worth
  re-running before you build the plan on it.**
  **The bug it existed to find.** Both editor sheets read their own `@State` inside
  `updateMetadata`'s `@escaping @Sendable` closure, which since 52 runs off-main — a real
  read of `name`/`role`/`quality`/language/script while the user can still be typing.
  Modal sheet, short window, so benign in practice, and *nothing but the compiler was ever
  going to report it.* Fixed by snapshotting on the main actor (`Edits`), not by
  annotating the capture away: the repo still has **zero** `@preconcurrency` and **zero**
  `nonisolated(unsafe)`, which is the property that makes the diff reviewable at a glance.
  Everything else was mechanical — `IngestOutcome`, `AttachOutcome`, `defaultFileRole`,
  `prettifiedVocabularyLabel` are pure values that only the module default put on the actor.
  *The test target, never measured before this, cost two diagnostics and no follow-up
  slice*: a non-`Sendable` `ArchiveLock` captured into a `@Sendable` closure — the holder
  now opens its own from the lockfile URL, so fork (c) held and nothing in the package had
  to move — and `DispatchSemaphore.wait()` from an async context, which Swift 6 rejects
  outright rather than warning about.

- **49 — the manifest covers everything authored.**
  `manifest.files` now carries every `record.json` and every `conclusions/**` record, so
  the archive's least reproducible data is finally inside the integrity surface. The
  invariant that makes it worth anything: **a present entry is carried forward verbatim
  and never re-hashed.** Re-deriving one would launder corruption — rot re-measured,
  written down as expected, clean forever after — which is why the manifest is now
  *partly authoritative* rather than wholly derived, and why blessing an out-of-band edit
  is an explicit `rebaseline()` that `open()` and ordinary commits must never call.
  Hashes are minted from the bytes `writeAuthoredJSON` just wrote; payload entries keep
  being derived from `record.json`, where their real authority lives.
  **The spec predicted the bugs would be in deletion and re-slugging** — carried-forward
  entries no longer fall out of a recompute, so each removal "must move or drop the entry
  explicitly". They aren't, because the entry *set* is enumerated from the index each
  time: a record that is gone contributes no path. The bookkeeping the spec expected was
  the bug, and not doing it is the fix. Same move made the one-line `rebaseline()`
  possible (empty `files`, let the recompute mint everything from disk).
  `commitManifest` moved into `withState` for the same reason — a mutation that forgot
  the call would now report the engine's own write as damage — and writes nothing when
  the list is unchanged, which is how fork (c)'s `updatedAt` rule stays honest in both
  directions.
  *Three tests failed, all of them correctly*: they pinned Phase 1a's "conclusions writes
  don't touch the manifest", which is the settled decision this slice revises. One of
  them was 51's evidence for the `data_version` poll over an mtime check — a conclusion
  write no longer misses the manifest, so that leg is gone. **51's choice stands**: an
  mtime poller re-fires on the app's *own* writes, and an external `reindex` still moves
  the token while touching no manifest. Both are now tests rather than hand-verified
  notes, since they went from supporting observations to being the whole argument.
  *Found, not fixed:* one undecodable sidecar makes `ArchiveIndex.rebuild` throw, so an
  archive with a missing/stale/dirty `.index/` **will not open at all**. Pre-existing and
  orthogonal, but exactly Phase 3.5 workstream (2)'s subject — noted there.
  **`/code-review` found five, and the two that mattered were both the same mistake**:
  a *classification* offered as a *promise*. The interrupted-write flag was a `let` taken
  at `open()`, so it missed a write that died in this session and never cleared after a
  rebaseline — and its app copy read "The file itself is intact", which the engine cannot
  know (the sentinel records that *a* write died, never which record). It is now a var
  with three transitions (set at open, set when `withState` throws, cleared only by
  `rebaseline`), and the wording no longer vouches for the bytes. Likewise the app's
  "Accept Current Contents" button fired on any checksum mismatch, including rot in a
  preservation master that `rebaseline()` provably refuses to bless — a scary
  confirmation followed by an unchanged report. The predicate now lives in the engine
  (`rebaselinableIssues`) beside the rule it depends on, rather than being re-derived
  from issue kinds by each host. `rebaseline()` was also emptying `files` wholesale,
  which silently re-minted the schema spec it claims not to touch; it drops only
  `isEngineAuthored` entries now.
  *The hand-test's first finding was the report saying nothing.* A pre-49 archive has no
  entries for its records, so a hand edit verified clean — correct per fork (f) (absent is
  *unverified*, not *tampered*) and indistinguishable from a real all-clear. A coverage
  **feature** was considered and dropped: the population is two archives on one machine,
  every mutation fills the entries in, and every archive born after this slice is covered.
  What shipped instead is one line — `verify` now prints how many files it checked — which
  costs nothing and stays useful long after the migration it was prompted by. **"OK" that
  cannot distinguish *checked everything* from *checked nothing* is the bug; the migration
  was only how we noticed.**
  *And one performance finding, taken with a measurement rather than a refactor.* Every
  conclusion write had started decoding every artifact's JSON — 4.63 ms/call at 500
  artifacts. The reviewer's fix (incremental entry maintenance) is the bookkeeping this
  slice deliberately doesn't do, so instead the index's `file` projection gained
  `path`/`byte_length` (schema v5, self-healing on open) and the recompute reads one
  join: 0.34 ms/call. The rest of what scales with archive size is writing the bigger
  manifest, which is fork (c)'s accepted cost and has its own measured number.

- **55 — one bad record must not close the archive.**
  `ArchiveIndex.rebuild` threw on the first sidecar it could not decode, and `open()`
  rebuilds whenever `.index/` is missing, stale or dirty — so **one corrupt byte in one
  `record.json` cost access to every other record**, with a decoding error and no path as
  the explanation. Now a per-record read/decode failure is skipped and reported; what still
  throws is the index failing to *store* what it read, which rolls back. All five forks
  shipped as specced: no threshold (an archive whose records are *all* corrupt still opens
  and explains itself), the skipped paths persist in the index (schema v6) so the finding
  survives an `open()` that walks nothing, and `verifyIntegrity()` reports what the last
  rebuild found rather than re-decoding everything.
  **The invariant, stated where it was only implied:** the sidecars are authoritative
  *and each of them independently*. Nothing about the archive's own consistency requires
  losing the other 2,999 records to one bad one — that was an unexamined `try`.
  **The composition with 49 is the reason (d) is cheap.** On a healthy index, an
  out-of-band-damaged sidecar is already caught by its manifest checksum; a record that is
  undecodable *and* absent from the index only arises when a rebuild ran. So the two
  reports answer different questions — *these bytes changed* vs. *this record is not in the
  index* — and an unreadable record usually appears under both, once per question, rather
  than the second check duplicating the first.
  **The review found that composition was broken, in the direction that loses data.** 49
  enumerates the manifest's coverage *from the index*, reading "absent from the index" as
  "the record was deleted". This slice created a third state — on disk, not indexed — so
  the next mutation silently dropped the record's entry **and every payload entry of its
  artifact**: rot in a preservation master then went unreported by anything, and repairing
  the record re-minted its baseline from disk, making **corrupt-then-repair a way to
  substitute a record's contents that `verify` reports as clean** — exactly the laundering
  49's carry-forward rule exists to prevent, around `rebaseline()`'s human gate. Fixed by
  completing the rule rather than patching a symptom: *a record the index cannot see keeps
  whatever coverage the manifest already had*, its own entry and its folder's. Both are
  regression-tested, and both were unreachable before this slice, because `open()` threw.
  **The lesson is about the shape of the change, not the code:** adding a state to a
  domain silently reinterprets every predicate that partitioned the old one, and
  "absent ⟹ deleted" was a *reading* of the index, never a checked invariant. Nothing in
  the diff touched 49's file, which is precisely why no test failed.
  *The gotcha, and it was in the test.* The "a store failure still throws" case was first
  written by setting the index file immutable — and **no error was thrown**, because SQLite
  writes happily through a descriptor it already holds. Permissions would have been the
  wrong lever regardless: the Linux CI container runs as root, where they are advisory, so
  the test would have gone quietly green there for a third unrelated reason. Dropping a
  table out from under the open connection is the portable, deterministic version, and it
  proves the rollback as well as the throw. *When a negative test needs an induced failure,
  the failure is the part to verify first.*

- **56 — damage announces itself.**
  55 made the archive survive a record it can't read; the hand-test found that the user
  still can't *see* that one is there — an unreadable artifact isn't rendered as damaged,
  it's rendered as absent, which is indistinguishable from never having been added. The
  findings were already in `.index/` and cost a `SELECT`, but the only way to reach them
  was `verifyIntegrity()`, which SHA-256s every tracked file. **The cheapest finding in
  the engine sat behind its most expensive call**, and that — not the detection — was the
  gap. Now: `standingFindings()` (free, read on open and on 51's poll), a window banner,
  and pinned placeholder rows in the artifacts and people lists.
  **The type is the design decision.** `StandingFindings` is a struct, not
  `[IntegrityReport.Issue]`, because without hashing "a write died" can only be said as a
  *flag* — `.interruptedWrite` names a file, and naming one requires exactly the
  comparison this call refuses to make. A type that cannot express a claim it cannot
  support is worth more than a comment saying don't.
  **Read-only rows, and that falls out rather than being chosen.** A record that failed to
  decode has no index row, so for an artifact there is no `ArtifactID` — it was inside the
  file that didn't parse — and every engine mutation is uid-addressed. So *every* action
  is unavailable by construction, delete included; Reveal in Finder is the only honest
  affordance. The rows carry no `.tag`, so the typed list selection cannot land on one.
  *Three things the live run caught that the spec didn't.* The empty-state branch: an
  archive whose only artifact is unreadable took the `artifacts.isEmpty` path and rendered
  "No Artifacts Yet" — **the exact bug this slice exists to fix, coming back through the
  empty state**, and invisible to a test that seeds two records. The row's headline read
  "Unreadable record — deed-of-sale-1899" on one line, which a narrow sidebar
  middle-truncated to "Unreadable re…-of-sale-1899", eating the one word the row exists to
  say; identity moved to its own line. And the banner, as a **top** `safeAreaInset` on the
  split view, silently displaced the sidebar's `.searchable` field — the Artifacts list
  lost "Search artifacts" for as long as the banner was up. It moved to the bottom edge,
  beside the wait bar. *All three were invisible to the test suite, and the third was only
  visible next to a healthy window — the control is what turned "nothing looks wrong" into
  a finding.*
  *And what `/code-review` added on top of that.* The placeholder rows preempted the "No
  Matches" state, so a search matching nothing showed only the damaged rows — a filter
  that finds nothing must still say so, and a record with no title can neither match nor
  fail to match, so placeholders now sit out an active search. The banner's dismissal was
  never reset, so damage arriving after a dismissal was silent for the window's life (and
  for a relationship or link, which has no row to fall back on, silent altogether); it now
  resets whenever the findings change. And `standingFindings()` swallowed an index read
  failure into a clean report — **the one call made on every refresh answering "nothing
  wrong" because something was wrong** — so it throws, and the app's rule is to keep the
  last known findings rather than downgrade a warning on a failed read.
  **The hand-test also pinned down what this slice does *not* do**, which the spec's fork
  (e) had implied too broadly: a sidecar corrupted on disk is not noticed until something
  rebuilds — not by the poll (`PRAGMA data_version` moves only on an index commit), and
  not by a reopen (a healthy index is used without a walk). **56 surfaces what the archive
  already knows; it does not go looking.** Verify Integrity does catch it, because 49 put
  sidecar checksums in the manifest — and catching it *cheaply* is precisely 57. Wording
  corrected in ROADMAP and in the test that covers the fork.
  **One unrelated fix rode along** (hand-test, and confirmed pre-existing by building
  `main`): a search with no matches left a band of dead space under the sidebar's search
  field, because `ListControlsBar` is a top `safeAreaInset` and `ContentUnavailableView`
  sizes to fit — so bar and empty state were laid out as one composite and centred
  together. The empty states now fill. **The rule, having been paid for twice in one
  slice: a top `safeAreaInset` in this sidebar needs content that fills, and must not be
  stacked on the container that owns the `.searchable` chrome.** `safeAreaInset` is still
  right for the bar itself — it is `.background(.bar)` precisely so rows scroll *under* it,
  which a `VStack` cannot do; both failures were about what it was applied *to*, not about
  the API.

- **57 — the cheap sweep.**
  56's hand-test left a hole: a file deleted or truncated *on disk* commits nothing, so
  nothing knows about it until someone pays for a full hash. Existence and size need no
  hashing — `manifest.files` records `byteLength` — so `sweepFileSizes()` is one `stat`
  per entry, run where 56's findings run.
  **The blocker was a measurement, and it had to come first.** On iCloud, a
  not-yet-downloaded file is *dataless*; if `stat` reported 0 the sweep would call every
  un-downloaded preservation master truncated, on exactly the archives that need it most.
  Measured on a real placeholder: **`st_size` is the true length** (700319 for a
  700319-byte file), while `st_blocks`, `fileAllocatedSize` and `totalFileAllocatedSize`
  are all **0**, `SF_DATALESS` is set, and neither `lstat` nor `resourceValues`
  materializes it. **The invariant: compare `st_size` and nothing else** — "optimizing" to
  an allocated size is now the only remaining way to build the false-positive engine the
  fork existed to prevent. `UF_COMPRESSED` on that same file is the second reason.
  **The wording was settled before any code, and the answer was to say nothing.** The
  sweep has no clean state — no banner, no "✓ 340 files checked". A cheap check that
  implies an expensive check's assurance is worse than no check, and the surest way not to
  write that sentence is to have nowhere to write it: `FileDamageSummary.init` is
  failable, so a clean report yields no value to render. This supersedes the spec's own
  "nothing obviously missing" line, which is honest but is a sentence a user rounds off to
  "verified".
  **Settled in the type before the strings** (56's precedent). The result is a
  `FileSweepReport`, reusing `IntegrityReport.Issue`'s kinds but *not* the wrapper:
  `isClean` means verified, and the next person to hold one would render it with the
  "Archive Is Intact" string that already exists. It is `foundNothingMissing` — a name
  that sentence cannot be written from.
  **The inversion worth remembering:** this sweep's *positives* are certain (the manifest
  says 700319 and `stat` says 4096 is a fact, not an inference); only its silence is weak.
  So the findings are stated plainly and it is the clean case that keeps quiet — the
  opposite of the instinct to hedge every line.
  *What the live run caught, in the same place 56's departures lived.* Archive paths
  repeat the artifact slug in the file name, so three full paths wrapped to **seven lines**
  in a narrow window and the banner ate a third of it. The banner names **file names**
  now, capped at two lines, with every full path in the hover text — a banner is not a
  list. Truncating the visible line to the tail would have been 56's mistake exactly
  (dropping the half that identifies the file), which is why the fix was to shorten what
  is shown rather than to let it clip.
  *And what `/code-review` added.* The sweep called a died-mid-write engine file a plain
  `.sizeMismatch` where `verifyIntegrity()` calls it `.interruptedWrite` — so **one on-disk
  state got two descriptions**, the banner accusing the archive of damage its own history
  contradicts while the panel behind it said a change didn't finish. Both calls hold the
  same three facts (sentinel, path, `isEngineAuthored`), so both now classify identically;
  the app counts only the two cheap kinds into its headline, which leaves 56's wording in
  charge of that case. Naming files by their last component then inverted for the one
  reserved name — every artifact sidecar is `record.json`, so two damaged records read
  "record.json · record.json" — now qualified by folder, as is any name colliding inside a
  summary. **The generalisable bit: "drop the redundant half" is a claim about a naming
  convention, and it flips wherever the convention does.** Also: `cancel()` cannot stop a
  synchronous walk that has already begun, so the comment claiming bursts don't stack was
  wrong — the check moved to before the walk and the comment now says what it actually
  buys. And a concurrent writer mid-mutation reads as missing files, so the walk re-checks
  that the manifest didn't move under it; that **narrows the window rather than closing
  it**, and closing it properly would mean holding the archive lock across the walk, which
  is the one thing this call exists not to do.
  **The measurement also found something out of scope:** `verifyIntegrity()` hashes every
  entry, and hashing a dataless file *materializes* it — so on a synced archive Verify
  Integrity is a whole-archive download from a menu item that doesn't say so, and 57 makes
  it more reachable by putting that button in a banner. Recorded in ROADMAP, not fixed
  here; the fix belongs on the expensive path.

- **58 — a rebuild must not destroy what it couldn't read.**
  Since 55 a sidecar that won't decode is skipped, so its index row doesn't come back —
  and that row is not a summary but a *byte-identical copy of the file*, written by the
  same deterministic encoder. Once the file is corrupt it is the only surviving one, and
  a rebuild deleted it: from the Verify panel's **Rebuild Index**, labelled *"Safe — it
  never changes your data"*, and from `Archive.open` on a dirty index, **before the user
  is told anything is wrong**. Skipped records now keep their row in a new
  `orphaned_record` table (index schema **v7**), dropped when the sidecar reads again or
  when a human discards it.
  **A separate table, not a `quarantined` flag** — same rule as 57's `FileSweepReport`
  not being an `IntegrityReport`: make the wrong thing *unavailable* rather than
  something every future `SELECT` has to remember to exclude. A preserved record is one
  the archive cannot read; surfacing it in a browse list would invert 55 and 56's whole
  story.
  **Which rebuilds it survives — the answer is "not all of them".** The copy lives in
  `.index/`, so it survives exactly the rebuilds that keep that file: the dirty sentinel,
  and an explicit Rebuild Index. A missing, corrupt or **schema-stale** index is resolved
  by unlinking the database first, so **58's own bump runs one last old-behaviour rebuild
  on the way in** — it recovers nothing already lost, and on an archive damaged at upgrade
  time it destroys the copy. Not fixable from inside the slice; a reason to ship early
  rather than a defect to file.
  Which rows to keep isn't known until the walk ends and the tables are cleared before it
  starts, so staging happens **in SQLite** — copy all, prune the readable ones in the same
  transaction — rather than holding the whole index in Swift while walking.
  **Fork (f) shipped here too, and it runs the other way:** an *edit* silently
  overwriting a sidecar that drifted on disk. `updateMetadata` and its siblings read from
  the index and blind-write the file without ever reading it, so a hand-edit — or an
  agent's CLI write while the app is open — is discarded by an edit that looks entirely
  normal. The guard sits at `writeAuthoredJSON`, the one chokepoint all 22 authored
  writes share, and **throws rather than writing-and-telling**: `recordDriftedOnDisk`
  leaves the other version on disk, and `rebaseline()` — *Accept Current Contents…*,
  `genea rebaseline` — is the existing, human-gated way through, so the slice needed no
  new UI. **It can afford an exact hash where 57's sweep could not**: one small file, so
  it catches the same-size hand-edit the archive-wide size sweep is structurally blind
  to. Four things are deliberately not drift — an unresolved interrupted write (57's
  classification, or every edit after a died write would be blocked), a path this
  mutation already wrote, a path with no manifest entry, and a file that is absent or
  unreadable.
  **The gotcha that shaped the implementation:** the baseline hashes are snapshotted into
  a property at the top of `withState`, not read from `manifest` — `withState` hands its
  body an `inout` binding to `self.manifest`, so reaching back through `self` for it is
  the exclusive-access trap `commitManifest`'s note already records.
  **And what `/code-review` found — the guard did not survive its own error path.** Its
  refusal throws from inside `withState`, whose catch armed the interrupted-write flag,
  which is the *first thing the guard checks*: so the guard switched itself off and an
  immediate retry overwrote the file it had just protected — with the error text's "then
  try again" leading the user there. The same flag was armed by *any* failed mutation,
  including validation-only ones that write nothing, and the sentinel they left behind
  re-armed it in the next process — one failed edit disabled the guard for a session and
  a half. **The generalisable bit: a signal that was safe as a conservative
  classification became unsafe the moment something started making a protection decision
  from it.** 49 could over-report "suspect" harmlessly; 58 could not over-suppress. Both
  are now narrowed by the same proof — `authoredWrites` is populated after each atomic
  write lands, so an empty one means no engine-authored file changed, and a failure that
  authored nothing is not an interrupted write and leaves no sentinel. Known residue,
  written down rather than papered over: a failure between moving files and updating the
  index (needs a SQLite error) no longer schedules a rebuild.
  Two more from the same review. Preservation pruned against `unreadable_record`, but a
  sidecar that is *gone* is skipped silently and never reported unreadable — so the copy
  was destroyed for the case that most needs it. The prune now asks **"is this uid live
  again?"**, which also stops a renamed artifact folder leaving a phantom restorable
  duplicate of a healthy record — the path-keyed rule would have kept one. And the
  staging copy was measured rather than argued about: over 600 records, rebuild **34.2 ms
  with vs 33.1 ms without**, index high-water 385 KB → 737 KB and stable across repeated
  rebuilds (pages are free-listed, not grown). Kept.
  **And what the hand-test found, which neither the spec nor the review did: a refusal
  has to leave *nothing* behind, not just leave the record alone.** Attaching a file to
  an artifact whose `record.json` had drifted refused the record edit correctly — and left
  the copied file in the folder, claimed by nothing, surfacing later as an unreferenced
  file. The file mutations all move bytes *first* and write the record afterwards, so the
  chokepoint sat downstream of the side effect. Attach, replace, detach and restore now
  raise the same refusal **before** touching the folder. **The generalisable rule: a
  chokepoint guard only covers what happens after it, so a mutation whose side effects
  precede its write needs the check hoisted to its own front.** `removeArtifact` is
  deliberately exempt — it moves the whole folder, drifted sidecar included, into
  `.trash/`, so there is no loss to refuse.
  706 engine tests on macOS (703 Linux), 141 CLI, 43 app.

- **59 — repair a damaged record from what the archive still knows.**
  56 offered a damaged record no action and was right to: the uid was inside the file
  that failed to parse, so every uid-addressed mutation was unavailable *by
  construction*. 58 made one case addressable by path instead — the index keeps the
  sidecar's own bytes — and 49 had already put that file's `sha256` in the manifest, so
  the file can be put back **and the restoration proved exact**. `repairPlan` says
  whether it can be; `repairRecord` does it; `genea repair --record` and a button on 56's
  placeholder row surface it, the row showing it only where a copy exists.
  **The quarantine went to a new reserved `.damaged/`, not into `.trash/` as the fork
  proposed.** `.trash/` is a **uid-keyed namespace** — `TrashStore.entries` reads each
  child's name as an item uid — so a folder there under any other name is
  indistinguishable from a *corrupt trash entry*, surviving on a leniency meant for
  those; and `purgeAll` deletes the whole directory, so Empty Trash would destroy
  evidence the user never chose to delete and no listing ever showed them. The cost that
  argued for nesting was checked and wasn't there: **no pass excludes reserved names by
  list** — all are scoped positively to `artifacts/`/`conclusions/`/`schema/` — so a
  third reserved dir needs no exclusion audit and can't be missed by one. Spec §2 in
  both copies, ARCHITECTURE and CLAUDE.md updated.
  **The gate asks what is being replaced, not whether the bytes check out** — and this
  is the one thing the spec had subtly wrong. Fork (a) reads as an exactness test, and
  an exactness test refuses the case with the *strongest* claim on a repair: a sidecar
  deleted out of band keeps its copy (58) but loses its manifest entry, because the
  carry-forward rule has no file left to describe. The most sympathetic damage therefore
  got a version-skew warning about an overwrite that cannot happen. **The generalisable
  bit: a proof-of-exactness gate is only meaningful where something is being destroyed**
  — which is 58's own drift-guard rule arriving from the other side ("absent is a
  repair, not a clobber — there is nothing left to destroy"), and the reason the two now
  read the same. Version skew still refuses without `acceptingInexactRestore`.
  Two smaller calls worth keeping. The restore writes the **preserved bytes**, through a
  `writeAuthoredData` sibling of `writeAuthoredJSON`, rather than decoding and
  re-encoding them: the encoder is deterministic so a round-trip would *almost always*
  produce the same bytes, and "almost always" is not what the manifest comparison
  promised. And `genea verify` now names the repair only on records that have a copy —
  fork (b)'s rule is about not offering what you cannot do, which is as true of a
  terminal line as of a button.
  Known residue, written down rather than solved: nothing empties `.damaged/` (one small
  JSON per repair; Reveal in Finder is the disposal), and a repair is not undoable — its
  inverse would be putting an unreadable file back, and the quarantine is what makes it
  reversible instead.
  **What `/code-review` found, and the thread joining all three: a per-item call, a
  copyable line and a spoken label each quietly assumed something about a caller.**
  `repairPlan(forRecordAt:)` looks like a `SELECT` and isn't — `withReadState` re-reads and
  decodes the whole manifest — so the app's row-at-a-time loop parsed `manifest.json` once
  per damaged record, on the main actor, on every refresh; `repairPlans(forRecordsAt:)` is
  now the call for a list, and both hosts with a list use it. `genea reindex` printed
  `genea repair --record <path>`, which is not a runnable command — it drops the archive
  positional — now fixed and held by a test that **parses every suggested line it prints**
  rather than eyeballing it. And the Restore button lived inside a row that is one combined
  accessibility element with a hand-written label, so VoiceOver announced the damage and
  never the affordance: the label and an `accessibilityAction` are now derived from the
  same `canRestore`, with the wording on `UnreadableRecordRow` where it is testable.
  **The generalisable bit: 56's rule was "don't offer what you can't do", and its mirror
  is "do announce what you can" — a hand-written label opts out of the automatic version,
  so every affordance added to that row is a label edit too.**
  **And what the hand-test found, which is the same trap 58's review found from the other
  side: `rebaseline()` blessed bytes nothing can read.** It re-minted every authored
  manifest entry from disk, including for records the rebuild had just reported
  unreadable — 49 weighed that and called it harmless, since the record stayed invisible
  either way. It stopped being harmless here, because that entry is now the **proof** a
  restore is byte-exact: accepting an unrelated hand-edit recorded the *corrupt* file's
  hash as the baseline, so the preserved copy no longer matched and a provable one-click
  repair silently became the labelled fallback — explained as version skew that hadn't
  happened. `rebaseline()` now carries those entries forward instead, which is the rule
  `recomputeManifestFiles` has applied since 55 and which this one call was the exception
  to. **The generalisable bit, twice in two slices: a claim derived from a signal is a
  new constraint on everything that writes it** — "accept what is on disk" has no meaning
  for a record with no readable version on disk.
  Found only because the seeded hand-test archive was wrong: its setup ran `rebaseline`
  *after* damaging two records, so both were mislabelled byte-exact and all three restores
  went through the fallback — **the headline path went untested until the seed's own
  premise was checked.**
  722 engine tests on macOS (719 Linux), 146 CLI, 48 app.

- **60 — the index knows whether it is current.**
  The index had four rebuild triggers and every one answered *is this database usable?*
  — none answered *does it reflect the files?* The fifth is a **witness**: a digest of
  `manifest.files` recorded in the index's own `meta`, compared at `open()` and on 51's
  poll. **No format change, and that is the finding rather than an absence** — §10.4
  wrote the generation-marker option as needing a home in the format, and slice 49 had
  already built one, so the witness digests data the format carries and only the index
  records which state it was built from. No `schemaVersion` bump either, deliberately: a
  bump takes the *new-file* rebuild path, which unlinks the database and would destroy
  58's preserved copies on the way in.
  **It adopts a change that arrives with its manifest, and only that.** A bare hand edit
  moves no manifest, so nothing here sees it — correct, not a shortfall: bytes that
  disagree with their recorded checksum are indistinguishable from rot, 49 reports them
  and 58 refuses to overwrite them, and rebuilding the query surface from them
  automatically would launder exactly what those two exist to catch. Pinned as a test so
  the boundary cannot erode.
  Cheap where it must be: a `stat` of `manifest.json` gates the digest, measured at
  **0.02 ms** for a no-op poll against a 369 KB manifest. Fork (d) settled by
  measurement rather than judgement — **500 artifacts rebuild in 43 ms, 2,000 in
  177 ms**, so a full rebuild stays and incremental was not needed.
  **The gotcha, and it recurred three times in three places: `recomputeManifestFiles`
  derives the authored set from the index, and that is wrong the moment a manifest can
  arrive from elsewhere.** A record the delivery has not brought is not in the index, so
  it contributes no path and its entry is deleted — from the only document that says the
  file is expected. The rewritten manifest then looks complete, the next reconcile
  settles it, and the record is lost when it lands. Round one fixed the reconcile path
  (adopt the delivered manifest, never recompute it); round two found every *other*
  mutation still doing it and needed `awaitedPaths`, gated on a delivery being in flight
  so ordinary deletion still drops its entry. **The generalisable bit: "derive it from
  the index" is a claim that the index is the authority, and a synced archive has a
  second one.**
  **The second gotcha was a circular signal, caught by 49's own regression test.**
  "A delivery is in flight" was first read as *the index has no witness* — but the
  completeness check is false for **any** mismatch, which is what `verifyIntegrity()`
  reports, so clearing the witness on damage made every damaged archive claim to be
  receiving one. The fix is to keep the last settled witness and define the signal as
  *the manifest on disk is not the one we last settled*: **corruption does not change
  `manifest.json`**, and that asymmetry is the whole distinction.
  Also: a mutation may only certify what it was entitled to certify (one unrelated
  `addPerson` after a delivery otherwise stamped the un-noticed stale index as current,
  through any number of reopens, with verify silent); stamp-before-read is now in the
  signature (`of(_:stampedBefore:)`) because stamping after a rebuild pinned the gate to
  a manifest it had never digested; and fork (e)'s back-off was specced and unbuilt
  until a review asked.
  The hand-test's two lessons were both about *surfaces*, not the mechanism.
  `.byteCount` rounds, and manifest mismatches are small — 1,656 against 1,652 both
  printed "2 kB", so a real finding read as a broken app. And **delivering records
  without their manifest is not a delivery**, it is a bare out-of-band edit; the test rig
  had to learn that too, having compared *sizes* to decide what had already arrived while
  the edit under test was fixed-length — the same size-only shortcut the engine takes for
  a reason (hashing a dataless file materializes it) and the rig had none.
  Left owed and specced as **61**: the arriving state has no passive surface at all —
  the damage banner is silent for it by design and Verify is a menu item.
  **One trap in the harness, found at the merge gate and worth knowing:** the *engine*
  passed on Linux while the *CLI* failed to compile it — `cannot find type
  'ManifestWitness' in scope` — because `scripts/linux-test.sh` gives each package its
  own `--scratch-path`, and `.build-linux-GeneaLogicCLI` had a build plan predating the
  slice's **new source file**. The kit's own scratch had been rebuilt and saw it. So a
  slice that *adds a file* to the engine can have its CLI Linux run fail on stale cache
  and read exactly like a genuine cross-platform break; `rm -rf .build-linux-*` is the
  whole fix, and it passed clean immediately after.
  746 engine tests on macOS (743 Linux), 146 CLI (Linux too), 55 app.

- **61 — a change on its way in should say so.**
  60 could tell *arriving* from *damaged* and said so only in the Verify panel, which
  nobody opens speculatively; the damage banner is silent for an arrival by design (57:
  the cheap sweep speaks only when it finds something). So the one state where the app
  knew something useful was the one state it kept to itself. Now a quiet bar in the
  window's bottom slot — spinner, one line, no count, no file names, no dismiss control,
  and deliberately **not** `StandingDamageBanner`, whose voice is the conflation 60 spent
  three rounds removing.
  **The signal is `deliveryIsInFlight` (made `public`, the slice's only engine change),
  not the sweep's `.awaitingDelivery` paths — because the boundary that matters is
  *adoption*, not arrival.** The witness only advances on a settling reconcile, so a bar
  keyed to the files landing would withdraw its own announcement up to a back-off before
  the record appeared in the list. Keyed to adoption, the bar goes at the instant the
  record shows up. **The cost is in the same fact and worth knowing: the bar stays up for
  up to 30 s after the last byte lands**, because 60's back-off gates the reconcile that
  adopts it — visible in the hand-test, and the right side of the trade rather than a
  defect.
  **Progress is measured app-side, from the sweep's outstanding set, not from the
  engine's back-off stamp**, which was the fork's assumed source: that stamp keys on
  `manifest.json`, so a multi-file delivery landing one file at a time under *one*
  manifest never moves it — exactly the case the stall threshold most needs to get right.
  Ten minutes and hedged wording, because a large file over a slow link is *structurally*
  indistinguishable from a stalled one: providers stage a download elsewhere and swap it
  in, so an in-flight file is simply absent throughout and there is no progress to see.
  The escalation therefore offers Verify Integrity rather than a diagnosis.
  **The rig found a silent data-visibility bug, now specced as 60b.** Deleting `.index/`
  before delivering — a real second machine's starting state — leaves no settled witness,
  so 60 stamps whatever is on disk as the baseline (its documented exception). When the
  rest of the delivery lands, `manifest.json` does not change again, nothing re-fires, and
  the record sits on disk invisible to every query while `verifyIntegrity()` reports the
  archive **healthy** — no banner, no prompt to rebuild. The root is one boolean doing two
  jobs: *the witness disagrees* and *there is no witness* are the same value, and the
  consumers want opposite groupings of them. Not patched here — 61's own out-of-scope rule
  sends a signal 60 lacks back to 60.
  **`/code-review` found one real defect, and it was fork (f)'s own mechanism biting
  back.** The sweep was cancel-and-replace, which was safe while `refresh()` was its
  only caller and stopped being safe the moment this slice put it on the 1 Hz poll:
  `sweepFileSizes()` has no suspension point, so a cancelled walk **runs to completion
  anyway** and only its *result* is discarded. On an archive where one walk outlasts one
  tick, every sweep was cancelled by its successor and nothing was ever published — the
  banner froze and the stall threshold, which measures progress from this sweep, would
  reach ten minutes on a healthy delivery. Requests now coalesce onto the running walk,
  which also bounds concurrency that cancel-and-replace never did (it started a new walk
  per tick and merely *marked* the old ones dead). **The generalisable bit: cancelling
  work that cannot observe cancellation is not throttling, it is discarding results.**
  The other two findings did not survive checking, and both were worth checking rather
  than taking: the "vacuous" arriving-file test **fails** when `.awaitingDelivery` is
  counted as damage, naming the file delivered in that test — the reconcile task's own
  `applyExternalChange()` starts the sweep before the task returns, so awaiting the
  reconcile first is exactly what makes it observe a post-delivery walk. And the
  disappearing damage banner is **60's, not this slice's**: the in-flight flag is
  archive-wide, so *every* mismatch is relabelled while a delivery is in flight. Measured
  on a rotted JPEG — `checksum-mismatch` becomes `awaiting-delivery`, and `genea verify`
  tells the user to **wait for a file that will never arrive**. Folded into 60b as its
  fork (d), being the one place where the witness's per-entry state gets decided.
  **The hand-test passed, and then asked the question the slice cannot answer: what
  happens when both machines edit at once?** Chased down rather than reasoned about,
  and the first answer was reassuring — an edit to the *arriving* record is refused by
  60's drift guard with "wait for the change to finish arriving", and an edit to any
  *other* record lands and survives the delivery intact. **The reported lost edit was
  the rig's fault**: `deliver.sh record` restored every file the delivered manifest
  named, rather than the files the other machine had actually *changed*, so a local
  edit made before the manifest arrived was faithfully reverted. A sync provider sends
  what changed on the sender; a rig that restores what the manifest describes
  manufactures a convincing engine bug. That is the second time this rig's shortcut has
  done so — see 60's size-comparison lesson — and both are now written into it.
  **What the chase did find is structural, and is recorded against 48–50:**
  `manifest.json` is a single file every mutation on every machine rewrites, so it is
  the guaranteed conflict point on *every* concurrent edit. Two machines editing
  **different** people leaves both records intact and the archive wedged — the
  surviving manifest describes the other machine's version of the record only this
  machine touched, so it reports `awaiting-delivery` for a file that will never arrive,
  the witness never settles, and 61's indicator sits there for ever. Which is the one
  consolation: **the escalation is load-bearing after all**, and in that state it is
  telling the literal truth.
  **The merge gate then failed, in a suite this slice never touched, and the harness
  is what was wrong.** `UndoRedoTests` reported a person still present after an undo
  and then crashed on an index out of range — but the failing line was *before* any
  undo, asserting that two `createPerson` calls had both landed. `settle()` had given
  up: it polls `hasMutationsInFlight` against a wall-clock deadline, and expired
  **silently**, handing the test a half-applied model to assert against. Two seconds
  was chosen on the reasoning that a write to an uncontended temporary archive is
  sub-millisecond — true of the archive, false of the *machine*, since suites run in
  parallel and this slice added one that clones archives and builds indexes. So the
  deadline is now ten seconds **and reports itself**, which also retires the argument
  for keeping it short: a timeout that says so cannot read as a hang. **The
  generalisable bit: a test helper that gives up quietly converts its own failure into
  someone else's, and the someone else was three slices away.**
  746 engine tests on macOS (743 Linux), 146 CLI (Linux too), 65 app.

- **60b — a first open must not certify what it hasn't seen.**
  60's no-witness exception recorded a witness unconditionally when the index had
  none, so that a fault in a pre-60 archive still reported as damage. But *no
  previous state to differ from* is not *this state is complete*: on a first open
  with no `.index/` part-way through a delivery, the witness certified files nobody
  had seen, `manifest.json` never moved again, nothing re-fired, and
  `verifyIntegrity()` called the archive healthy while a delivered record stayed
  invisible to every query. Reachable from any copy, restore or `rsync` that drops
  `.index/`, which 48 makes the normal case.
  **The fix is a three-state `WitnessState` — `matches`/`disagrees`/`unknown` —
  computed once and switched on explicitly**, replacing one boolean that was false
  for two unrelated reasons. Deliberately not a second bool: two booleans admit a
  fourth combination that cannot occur, and the defect was a value that could not
  express the case it was asked about. `recordWitness` now writes nothing when the
  delivery looks incomplete, full stop — leaving `.unknown`, which
  `indexLooksStale()` already treats as stale, so the state resolves itself on the
  next open.
  **The trap is that `.unknown` groups differently per consumer, and the two
  directions are opposite.** Where a false *arriving* would **mislead** — the
  banner, the issue kind, 61's bar — unknown reads as damage, which restores the
  removed exception's purpose by an honest route. Where a false *not*-arriving
  would **destroy** — `awaitedPaths`, the only thing keeping an un-arrived file's
  manifest entry alive — unknown must stay on the in-flight side. **A split that
  maps only `.disagrees` to "in flight" walks 60's manifest-scrubbing data loss
  back in through the unknown door**, and the test for it fails on `main` exactly
  as the headline bug does.
  Fork (c) added a third drift-guard error (`recordDriftedWithNoHistory`): with no
  history, *accept the current contents* would discard an incoming version and
  *wait* would promise an arrival on no evidence, so it says which it cannot tell.
  Fork (e)'s cost — a damaged archive re-walking on every open — is accepted and
  **bounded by the check being `st_size`**: only wrong-size damage keeps an archive
  unsettled, so rot that preserves length, and every intact archive that merely
  lost its index, settles on the first open and never walks again. Pinned as a
  test, since that is what makes the cost small.
  **Fork (d) was lifted out as 60c** rather than settled here: it is the one item
  that adds a mechanism (per-entry witness state) instead of retracting a claim the
  engine had no right to make, and a correctness fix buried inside a new mechanism
  is harder to review than either alone.
  **`/code-review` found two, and the first is the better lesson: widening a
  conservative rule widens what it gets wrong.** `awaitedPaths` reads *the index no
  longer names this path* as **still in flight** — sound only for a path nobody
  asked to delete. Deleting anything while the witness is unsettled therefore
  carried a phantom entry naming a file that will never exist, and that is
  **permanent and self-sustaining**: completeness is false for ever, so the witness
  can never settle, so every later mutation carries the entry again, so
  `verifyIntegrity()` reports a missing file on every open — with
  `deliveryIsInFlight` **false**, so no surface explains it. The trap pre-dates 60b
  (it needs only `.disagrees`), but 60b routes every index-less archive through it.
  The fix is the mirror `authoredWrites` always needed: `removeAuthoredFile(at:)`,
  now the chokepoint for all seven conclusion-removal sites that had grown the same
  three lines, plus one note from `removeArtifact`, whose folder leaves by *rename*
  into `.trash/` and so passes no unlink at all. **The generalisable bit: "the index
  doesn't name it" answers two questions — *not here yet* and *deliberately gone* —
  and only the mutation itself knows which.**
  The second was a claim of the exact kind this slice exists to delete. `.unknown`
  had swallowed *manifest unreadable right now*, so an archive that had been
  settling deliveries for months could be told **"this copy has no history yet"**.
  A witness plus an undecodable manifest is `.disagrees`: `AtomicIO` renames a
  complete, decodable manifest into place, so this engine never leaves one in that
  state, and something else did. That also restores exact pre-slice behaviour there
  — which is the point, since 60b's subject is the *no-witness* case and nothing
  else should have moved.
  **The rig gained `deliver.sh unsettle`**, which drops mine's `.index/`: `setup`
  deliberately settles one first, so the state this slice is about was previously
  reachable only by hand surgery. 60c and 48 will want it too.
  756 engine tests on macOS (753 Linux), 146 CLI (Linux too), 65 app.

- **60c — a delivery in flight must not speak for damage it did not cause.**
  60's in-flight flag is archive-wide, and said so: it reports that *a* delivery is
  in flight, never which files it covers. Every consumer then relabelled **all**
  mismatches, so a JPEG that rotted months earlier reported as `awaiting-delivery`
  for the length of any unrelated sync — `genea verify` told the user to wait for a
  file that will never arrive, the damage banner went quiet for the duration, and
  because the summary changed to nil and back, a dismissal they had already made was
  reset on the way back.
  **The fix is a per-entry witness: the settled manifest's entries in `.index/`,
  written by the same call that records the witness** (one parameter, not a second
  call — a state where one advanced and the other had not would answer the
  per-entry question from a manifest the engine no longer holds). The whole
  question is then one comparison: *in flight, **and** this path's entry moved
  since the last settling*. A path the settled manifest named identically is
  damage, whatever else is arriving.
  **Three sub-cases fall out of that one line rather than needing mechanism**, and
  that is the reason to state it as one line. `.unknown` is already not in flight,
  so 60b fork (c)'s "no history stays damage" costs nothing. A path the settled
  manifest never named is the delivery — otherwise every genuinely new record
  reports as damage while it lands. And an **empty** settled set is a meaningful
  answer, not a missing one: everything reads as covered, which is 60's coarse
  behaviour, kept for the two states that cannot do better rather than replaced by
  a fresh accusation of damage.
  **The second of those states was found by 60b's own suite, and is the gotcha.**
  `.disagrees` has two shapes and only one can be asked about a file: when
  `manifest.json` does not decode, every consumer is holding the *settled* manifest
  (`reloadManifest` keeps the last good one), so comparing it against the settled
  rows finds every path unchanged and calls the whole delivery damage —
  reintroducing exactly what 60b's `/code-review` had removed. Coverage therefore
  re-reads the manifest and falls back to the archive-wide answer when it cannot.
  **The drift guard was added to the slice before building**, since fork (b) named
  only the two report paths: it picked its advice from the same archive-wide flag,
  so any delivery in progress turned a locally drifted record into one that was
  "still arriving" — the same wrong advice one layer over, decidable from the hash
  it already holds in `authoredBaseline`.
  **No format change and no `schemaVersion` bump**: `settled_file` is additive
  `CREATE TABLE IF NOT EXISTS`, and a bump would take the new-file path, which
  unlinks the database and destroys 58's preserved copies of unreadable records.
  The rows are rewritten only when the witness digest they were written from
  changes, so the common re-record — every mutation, and every open whose stamp
  moved without its contents changing — touches no rows; an index from before the
  slice has no marker and backfills on its first settled open.
  **`/code-review` found three, all in the new storage rather than in the rule.**
  The one worth keeping: a `manifest.json` naming the same path twice made the
  archive **fail to open**, because `settled_file.path` was a primary key and
  nothing else in the engine treats a duplicate as fatal — `authoredBaseline`,
  `authoredEntries` and `repairPlans` all quietly keep the first. *A new index
  table inherits the tolerances of the data it copies*; `INSERT OR IGNORE` keeps
  the same first-wins rule. The other two were cost: preparing the insert per row
  was ~80% of the rewrite (one statement now, halving it), and `deliveryCoverage`
  decoded `manifest.json` a second time just to learn whether it decoded — folded
  into the comparison that had already done it, with the settled rows cached
  under the marker they were written from, so an in-flight archive scans them
  once per settling rather than once per poll. **What is left is accepted with
  its measurement**, as fork (e) accepted 60b's: rewriting the entries is
  O(entries) SQL per mutation — 2.1 ms at 1,000, 45 ms at 20,000, against 1.3 ms
  and 21 ms for writing `manifest.json` in the same mutation. The alternative
  that writes 12× faster (one blob) reads 6× slower on the in-flight path, and
  the escape hatch is named in the code rather than built: `commitManifest` holds
  the previous manifest, and the marker proves the rows describe it, so the delta
  is computable without reading them back.
  **The hand-test then found the worst one, and it pre-dated the slice**: the
  *completeness* gate was archive-wide too, so an archive that was already
  damaged when a delivery landed **could never settle again** — the rotted file
  is the wrong size for ever, `recordWitness` therefore wrote nothing for ever,
  and `deliveryIsInFlight` stayed true with nothing arriving. 61's bar up
  permanently, every open re-walking the archive, `awaitedPaths` still carrying,
  and no surface able to explain any of it, because the delivery had in fact
  completed. Same rule, third consumer: an entry unchanged since the last
  settling is not what the delivery is bringing, so its bytes cannot say whether
  the delivery finished. What the gate exists for is untouched — an un-arrived
  `record.json` is named by an entry that *did* move, so it still holds the
  witness back. **Folded in rather than deferred** (2026-08-28): it is the same
  defect the slice is named for, and 60c is what makes it decidable.
  767 engine tests on macOS (764 Linux), 146 CLI (Linux too), 66 app.

- **48 — the index is machine-local.**
  `.index/` is inside the package, so a provider syncs it: two machines wrote one
  `index.sqlite`, one `lock`, one `dirty`. Now `.index/<machine-key>/`, so no two
  machines write one file, no provider reconciles a live database, and each machine
  keeps its index warm across handoffs.
  **What decides the key is agreement, not stability.** The sandboxed app and the
  unsandboxed CLI must derive the *same* one, or 47's `flock` silently stops
  excluding — which is precisely how Application Support failed as a home for
  `.index/`. So it was **measured before anything was built**: an ad-hoc-signed
  sandboxed bundle and the plain CLI read `/`'s `volumeUUIDString` identically.
  Hashed into `<derivation>-<16 hex>`, which is what lets the
  `GENEALOGIC_TEST_MACHINE_KEY` seam skip a charset allow-list — the value never
  becomes a path component — while the prefix stays in the clear so a divergence is
  visible from `ls`.
  **No migration, by decision:** a legacy `.index/index.sqlite` stays put and the
  machine directory starts empty. The rebuild that costs is one an empty directory
  forces anyway, so migration code would have bought nothing.
  **The gotcha is the one 47 wrote the rule against.** "Resolved through
  `ArchiveLayout`, never hardcoded" held for the engine's *paths* — one edit moved
  all three files — but two things had climbed out of it: three tests writing
  `.index/dirty` as a literal, and `ArchiveLock` reconstructing the archive root by
  going two directories up from the lockfile, which then reported `.index/` as the
  busy archive. A wrong path in an error message, found only because a test asserted
  on it. The lock now carries the root rather than deriving it.
  **`deliver.sh` had to grow a second machine to test this**: two copies on one real
  machine derive one key, and `record` never delivered `.index/` at all, so the
  collision was unreachable by the rig that exists for exactly this.
  **Review found the rig could still stage the failure it now disproves** — the
  header invites hand-editing either copy with a plain `genea`, which gives `other`
  a directory named with *mine's* key, and delivering it would land a foreign index
  on mine's live database, indistinguishable afterwards from the engine doing it.
  Third rule in the header: never deliver onto the receiver's own key.
  **The silent-fallback risk got a voice rather than a fix**: `MachineKey.derivation`
  is public, and `genea` announces a key derived from the hostname — on Darwin that
  means the volume UUID was unreadable, which is the shape of an app/CLI divergence.
  The app has no such notice yet. `/etc/machine-id` went in ahead of the hostname
  and does *not* rescue containers (measured: empty in `swift:6.3`).
  780 engine tests on macOS (777 Linux), 146 CLI (Linux too).

- **50 — the manifest survives two machines.**
  Two machines edit **different** records, both sidecars sync intact, and the archive
  wedges anyway: both rewrote `manifest.json`, the provider picked one, and the
  survivor names the pre-edit hash for a record only the other machine edited. 60c
  reads that moved entry as a delivery — of a version that exists nowhere — so the
  witness never settles and the record is **frozen against every further edit**, with
  advice forbidding the one operation that would clear it. `manifest.files` is a set of
  independent per-path facts, not a narrative, so it is merged per path instead of
  adopted whole.
  **The invariant that lets it run without a human: the merge mints nothing.** Every
  entry it emits was authored at write time by one machine or the other, so 49 fork
  (a)'s no-re-hashing rule holds by construction — which is exactly why `rebaseline()`
  needs a human and this does not.
  **The gotcha cost a rewrite, and the existing tests found it in minutes.** The specced
  rule was *the disk agrees with our settled entry, so their manifest predates our
  write* — equally true of a delivery still **in flight**, where the disk holds the old
  version because the new one has not landed. Six delivery tests from 60/60b/60c failed
  and were right to. The two manifests cannot separate those cases from each other; what
  separates them is a third fact on neither of them — **that we wrote, and what we wrote
  over**. So the merge is three-way, over a machine-local record of what each local write
  superseded, dropped when the sender's manifest names our entry. Lose it and the merge
  degrades to slice 60's take-it-whole, which is safe.
  **`/code-review` found that record wrong in both of its dimensions.** It kept only the
  *first* predecessor per path — right for a machine editing offline, wrong on the second
  round of any exchange: once the other machine adopts our E1 and writes again its
  manifest legitimately names E1, and a local E1→E2 in the meantime made the merge take
  theirs and wedge the archive exactly as before the slice. What identifies a stale
  manifest is not the first version but **any version we have moved on from**, so it is a
  set. And it was one `meta` blob, decoded and re-encoded on *every* manifest-changing
  mutation to add one predecessor — O(everything ever edited) under the archive lock, on
  a path the blob's own justification claimed it never took. Rows, keyed
  `(path, sha256)`: the write is O(paths this mutation changed) and only the merge, which
  is rare, reads the set. The opposite trade from `settled_file`, because the access
  pattern is the opposite.
  **Restoring entries the arriving manifest does not name was built and reverted:**
  nothing tells that apart from a manifest legitimately rolled back by hand, which 49
  fork (f)'s compatibility test pins.
  **A stale `.build-linux-GeneaLogicCLI` had been hiding the CLI's Linux run since 48**
  — cleared, and it revealed one real failure: 48's machine-key stderr notice is the
  first line in the container, and a test asserted positionally on stderr.
  800 engine tests on macOS (797 Linux), 146 CLI (Linux too).

- **50b — a deletion of yours is not a delivery.**
  50's wedge, one case over: delete a record here while the other machine writes anything
  at all, and the manifest the provider keeps still names the record you deleted — an
  entry in neither the settled entries nor on disk, which 60c reads as a delivery of a
  version that will never arrive. Worse than 50's shape in one respect: `awaitedPaths`
  re-adds the phantom entry on **every later mutation**, so the manifest permanently
  describes a file that cannot exist and the deletion can never be re-made.
  **The evidence 50 built already decided it** — `recordWhatThisMutationSuperseded` notes
  the entry a *deletion* replaced exactly as it notes an *edit*'s. What 50's rule could
  not do with it is the other half of the sentence: it only ever **substitutes** an entry,
  and a deletion needs one **dropped**.
  **The invariant is three facts, and the first is the whole safety argument:** drop when
  **this machine recorded removing the path**, we superseded that version, and nothing is
  there. Without the first, a record we had *edited* whose file was lost out of band
  satisfies the other two and the merge silently withdraws a real `missingFile` finding.
  **`/code-review` found that first fact written as an absence — our settled entries do
  not name the path — and absences do not hold here.** `settled_file` moves only when a
  mutation starts current or a delivery settles, so while one is stuck in flight it lags
  arbitrarily: a record created *and then edited* in that window is in `superseded_file`
  and has never been in `settled_file`, and the withdrawal fires on a real loss
  (reproduced). So the deletion is recorded where it happens — a `deleted_path` table,
  cleared when the path is authored again — and asked **before** 50's substitution, since
  `settled` may still name a path we deleted and the substitution would then keep theirs
  and leave the wedge. Additive, no `schemaVersion` bump: an empty table drops nothing,
  which is slice 50's behaviour.
  **The hand-test found the one place the per-path rule is wrong.** An artifact's record
  and its payload are not independent facts: delete an artifact here while the other
  machine edits it, and *a delete loses to an edit* brings the record back while the
  payload entry is still dropped as our deletion — a record listing a preservation master
  that is on no disk, in no manifest, and reported by nothing, its only copy in `.trash/`,
  which emptying deletes for good. Before the slice that same race wedged the archive and
  reported the file outstanding: **noisy and honest is the direction to fail in**, so a
  dropped path under an artifact folder whose `record.json` survived is un-dropped, and
  the file is reported again (as *which* finding is 50d's question, not this slice's).
  Restoring the payload *from the trash* was rejected with it — the merge mints nothing
  and runs without a human, and `.trash/` is outside every integrity pass.
  **A second `/code-review` found that coupling too broad and the evidence too loosely
  armed.** "Its record survived" is trivially true of a record nobody deleted, so a
  `detachFile` on a *living* artifact put its entry back and re-wedged the archive one
  case over — the record must have been deleted too. And the note was taken from the
  manifest diff rather than from the mutation's own `authoredRemovals` (now widened to
  cover deliberately removed payload paths), and was only ever cleared by a *local* write
  — never by the commonest return path, the merge keeping theirs — so it is now dropped
  once the path is back on disk. *The `authoredRemovals` gate is hardening: no route was
  found where an entry leaves the manifest without a deliberate removal.*
  **And *nothing is there* is `lstat` failing with `ENOENT`**, not any `stat` failure:
  a directory, a dangling symlink, or an `EACCES` on a parent is something to report, and
  reading "I cannot answer" as "deleted" licenses the drop on the machine that can see
  least.
  **A delete loses to an edit, and that fell out rather than being built:** if the other
  machine edited the record, its manifest names a version we never superseded, so we keep
  theirs and the record returns when it lands — and the sidecar is in `.trash/` either way.
  **The evidence for a deleted path cannot be pruned**, which makes 50's unbounded-growth
  residue slightly worse and is stated rather than implied: 50 prunes on positive proof
  the sender holds our current entry, and a path it has simply stopped naming is no such
  proof — an older manifest can arrive at any time from a restore.
  **Restoring entries the arriving manifest does not name stayed declined** (50 built and
  reverted it): our new record and a record the *other* machine deleted whose
  file-deletion has not landed are the same picture from here, so restoring would re-wedge
  on a file that will never arrive. Measured, that residue is a *window* — the next write
  mints the entry.
  821 engine tests on macOS (818 Linux), 146 CLI (Linux too).

---

- **50d — nothing is coming, and the way out.**
  The one state 50 and 50b deliberately left standing: `manifest.files` expects a version
  that never arrives and **no evidence decides it**, so `verifyIntegrity()` reports
  `awaiting-delivery` for ever, the witness never settles, and the record is frozen — with
  the engine's own advice forbidding `rebaseline`, correctly, because for a delivery that
  is merely *slow* waiting is the right answer. The only evidence available is time without
  progress, which is a hedge, so the verb is a human's: `genea abandon-delivery <path>`,
  one path at a time, no `--all`.
  **Dropping the entry is the whole implementation** — `rebaseline`'s mechanism at one
  path. The closing recompute then mints from the file that is actually here, or (where
  nothing ever arrived) contributes nothing.
  **Two engine bugs the tests found, both in the commit path.** `commitManifest` compares
  the recomputed list against **the list the body left behind**, so the one mutation whose
  entire effect is a removal that adds nothing back recomputed to exactly that list and
  **skipped the write** — the removal lived in memory until the next `reloadManifest()`
  discarded it. And the abandoned entry was recorded as one *we superseded*, which is the
  opposite of true: we never had that version, we gave up on it. 50's merge would then have
  read a genuine later delivery of it as a stale manifest and **discarded the very version
  the user stopped waiting for** — the difference between *recoverable* and *lost*, and
  recoverability is the entire licence for offering this where `rebaseline` is refused.
  **The note has to be self-describing.** Clearing it from the mutation path is not enough:
  an arrival is adopted through the delivered-manifest branch, which recomputes nothing and
  has no before-and-after, so the note survived the event that falsified it. `abandoned_path`
  stores the checksum the abandonment left standing (empty = entry dropped) and readers
  decide it against the manifest in front of them. It is carried **beside** `issues`, never
  in them: a decision the user made is not a finding, and folding it in would make `isClean`
  false for ever.
  **The gate is the anti-laundering rule.** The verb accepts only a path a delivery actually
  covers — the same question `verifyIntegrity()` asks — so a disagreement no delivery
  accounts for is refused as damage rather than re-minted from disk under a friendlier name
  than `rebaseline`. Deliberately **not** gated on elapsed time: that would dress 61's hedge
  up as a diagnosis.
  **One of the three causes the spec named does not reach the verb, and the tests said so.**
  A recreated `.index/` has no witness, which 60b routes to *damage*, not to an arrival — so
  the archive never says "wait" there and the verb refuses it. Pinned as a test so the claim
  is not carried forward as though it had been built.
  **A wording bug the rig caught and the tests could not:** the note read *"the manifest
  records this machine's copy"*, false for the absent case where there is no copy. The note
  explains the decision; the manifest already says which shape it was.
  **`/code-review`: the gate was asking a narrower question than `verifyIntegrity()`,
  twice.** A **payload** path was a silent no-op — `payloadEntries` re-derives an attached
  file's entry from the `record.json` that claims it, so the drop achieved nothing while the
  note was still written, and `verify` then reported one path as *both awaited and abandoned*
  for ever. Refused now, with `rebaseline()`'s scope rule and its reason: the manifest does
  not author that checksum, and the remedy is to detach the claim. And **`.interruptedWrite`
  outranks `.awaitingDelivery`** in verify, so with the sentinel set the verb was blessing
  what may be half a commit of ours and routing around `rebaseline()`'s warning; the guard
  now sits ahead of the coverage test, in verify's own order. **Writing that guard deadlocked
  on the first run** — `interruptedWriteSuspected` takes `lock` and `withState`'s body is
  already inside it, so it gained a `…Locked` sibling like `deliveryCoverageLocked()`.
  **The same review found the note only half-cleared:** filtered on read, never deleted, so a
  dropped-entry note stood *again* the moment anything later removed the entry that had
  replaced it — a decision the archive claimed nobody made. Pruning runs on **both** commit
  paths now, the delivered-manifest branch included, since an arrival is what most often
  falsifies a note and that branch recomputes nothing.

---

- **50c — a conflicted copy must not become the record.**
  The 48–50 placeholder read this as *an unexpected file beside a record* — a detection
  problem. Measured on a demo archive first, it was worse than that in two of its three
  shapes, because **two discovery walks were name-blind**. `loadConclusions` decoded every
  `*.json` in `conclusions/<kind>/`, so a provider's copy landed in the index under the same
  uid as the original; `contentsOfDirectory` order decided which one won; and **the next
  ordinary mutation wrote the winner back into the canonical sidecar** — `person name add`
  turned *John Smith* into *John Smyth-STALE* on disk with `verify` clean throughout. Silent
  data loss through the normal path, not a stray file. The rebuild reading `record.json` in
  every subdirectory of `artifacts/` is the same defect one level up, and there the loser was
  invisible to `verifyIntegrity()` as well, because `findUnreferencedFiles` only scans slugs
  the *index* knows — precisely the folder that lost.
  **The invariant is one uid, one file**, decided on structure and never on the provider's
  naming: `(conflicted copy` and ` 2.json` are localizable and brittle, while *two files
  claiming one uid* holds whatever wrote them and catches a plain `cp`. A conclusion loads
  only from `<uid>.json` whose inner uid agrees — both halves, or the rule is enforceable by
  renaming a file. Where two artifact folders claim one `ART-…` the manifest's incumbent wins
  (its entry predates the copy), falling back to the lexicographically first path, which is
  arbitrary but identical on every machine — the property that keeps two machines from
  disagreeing about which file is the record.
  **Reported, never moved.** `.damaged/` looked like the shape to borrow and is not: it holds
  bytes a repair had to *displace*, while here the real file is already in place. Quarantining
  would mutate the package on a **read**, fight a provider that re-delivers the copy until the
  conflict is resolved at its source, and carry off the only copy of what the other machine
  wrote. Hence `.conflictingCopy` — its own kind, not `.unreferencedFile`, because "stray"
  invites deleting it unread — and its own app section for the same reason.
  **The spec was wrong where it mattered.** §2 claimed every file but `record.json` and
  `manifest.json` is referenced by `path` from a `record.json`; conclusions are discovered by
  *scanning*, and the canonical `<uid>.json` name the engine already writes and expects was
  written down nowhere. Both copies now say it, with the tie-break, and the §2/§6 headings
  stop calling a uid a slug.
  **Two gotchas.** A test that leaves both files in place proves the invariant but can pass on
  a lucky enumeration — the load-bearing regressions are the ones where the copy is the *only*
  candidate, or carries a different uid than its name, so no ordering is involved. And the
  Linux CLI run failed with `cannot find 'RecordDiscovery' in scope` while the engine run
  passed: `.build-linux-<package>` had cached the source list, and a **new file** in a
  path-dependency is invisible until that scratch directory is cleared.
  **`/code-review` found the slice hurting the data it exists to protect, twice.** A provider
  that resolves a conflict by renaming the *original* leaves the record's **only** copy under
  the wrong name — reported as a duplicate, with advice to delete it, and the `.missingFile`
  companion that kept it honest is dropped by `recomputeManifestFiles` on the next mutation.
  Now its own kind, `.misnamedRecord(path:uid:)`, grouped with `.unreadableRecord` because the
  archive is serving no such record, and stating the rename that restores it. And **the
  lexicographic fallback was not arbitrary, it favoured the copy**: `' '` (0x20) and `'('`
  (0x28) sort under the separator `'/'` (0x2F), so on the full path both providers' names beat
  the original *deterministically*, on exactly the archives with no incumbent to save them (a
  pre-49 manifest names no records). Compared at the folder, the original is a strict prefix.
  The fork's claim that lexicographic order "happens to pick the original" was backwards and
  untested — a tie-break's *stability* is easy to assert and says nothing about its direction.
  Two more from the same review: verify **re-derived** the winner rather than asking the index
  what actually won (a copy arriving moves no manifest, so nothing rebuilds, and the two can
  diverge into naming the file the archive is serving); and Dropbox's real behaviour is a
  *file*-level conflict, `artifacts/<slug>/record (conflicted copy).json`, which the scan
  never looked at and the stray sweep filed under "Stray Files" — the one label whose wording
  invites deleting a record unread.
  **The app hand-test found a claim with nothing under it, twice over.** The misnamed row
  *stated* a remedy — rename the file — from a panel with no way to reach a file inside a
  package bundle; it now carries **Reveal in Finder**, which touches nothing and does not
  dismiss the sheet, because the remedy has a second half. That half was the other finding:
  after the rename the row disappears (verify walks the disk fresh) while the record stays
  invisible until **Rebuild Index**, since renaming a conclusion moves no `manifest.json` and
  the witness still matches. §5.1 working as written — but 50c is the first thing in the
  product that tells a user to make an out-of-band edit, so advice that stops before the
  rebuild is advice that leaves them worse off than silence. Both surfaces now name the whole
  remedy. **And `sectionsCoverEverySeverity` did not exist**: the panel's doc comment has
  promised it since 60, and this slice added a severity trusting it. The one time the net was
  needed it was not there — written now, with two siblings.
  857 engine tests on macOS (854 Linux), 151 CLI (Linux too), 72 app.

---

- **57b — verifying must not download the archive.**
  `verifyIntegrity()` SHA-256s every manifest entry, and hashing a dataless file
  *materializes* it — so on a synced archive Verify Integrity was a whole-archive
  download started by a menu item that did not say so, ending in **Archive Is Intact**.
  Recorded as 57's out-of-scope finding; brought forward because 50c fork (f) made that
  call the only surface for conflicted copies, which occur on exactly the archives where
  running it is most expensive.
  **The skip is the hash and nothing else.** Presence and size are still checked on a
  placeholder, because `st_size` is its **true** length (57's measurement) — so a
  cloud-hosted master whose recorded size no longer matches is still reported as damage,
  and the cheap sweep and the expensive one cannot disagree about it. What is not paid
  for is the download.
  **The invariant is that `isClean` stops meaning *verified* the moment anything is
  skipped.** It stays true — nothing was found, because nothing was read — so the report
  carries `notChecked` beside `issues` (50d's `abandonedPaths` shape: a note, not a
  finding) and an `isComplete` the *Archive Is Intact* headline gates on. Same rule as
  `FileSweepReport.foundNothingMissing` one tier down: the property the false sentence
  cannot be written from. The CLI's clean line says **PARTIAL** and names the counts;
  neither surface changes the exit code, because a file we declined to download is not a
  fault.
  **The cost is stated in bytes, and it is free to state**: `byteLength` is in the
  manifest for every entry, so *"41 files, 3.2 GB are not on this machine"* costs no
  disk access. A bare count is not a decision.
  **One injectable seam, because CI cannot make a placeholder.** 57 measured
  `SF_DATALESS` by hand and could hold no more than *nothing local is dataless*; skipped,
  checked, opted-in and Linux-no-op would all have been claims. `verifyIntegrity(
  includingDatalessFiles:isDataless:)` takes the predicate; the signal in production is
  unchanged. **Off Darwin `Archive.isDataless` is `false` by construction**, not by an
  `#if` in the walk, which is what makes Linux byte-identical rather than merely similar.
  **One departure, and it is the app's:** the panel's verify moved off the main actor.
  It was a synchronous main-actor hash pass — already a long freeze on a big archive, and
  an *unbounded* one the moment a button on it can start a transfer. A frozen window for
  the length of a download is not a thing to put a button in front of.
  **Accepted and worth stating:** the record-discovery walk still reads sidecars, as
  `rebaseline()` does. They are kilobytes, and a report that could not read the records
  could say nothing about them; the gigabytes are all in the payload hashing.
  **`/code-review` found the same claim leaking back in three ways, all fixed here.** The
  hash was a `try?`, so a file the pass could not *read* vanished from the report entirely
  — clean **and** complete over a file nobody looked at, on the path this slice added, and
  a failed download is exactly how that happens. `notChecked` therefore means *unread*
  rather than *skipped*, and carries a `Reason`. Chasing it one layer down found the older
  half: `InputStream.open()` reports failure only through a status nobody read, so an
  unopenable file hashed as **empty** — a real digest, wrong, compared against the manifest
  and reported as corruption. Second, the panel contradicted itself: a dataless file with a
  size mismatch is in *both* lists by design, and the unread row said "present and the right
  size" directly under a Corruption row saying otherwise. Third, the download ran in an
  unstructured `Task` with no cancellation point anywhere beneath it — Done dismissed the
  sheet and the transfer carried on invisibly. It is now cancellable **between 1 MiB
  chunks** (a per-file check would not stop a placeholder read that blocks *inside* the
  loop), with a Stop button, cancel-on-dismiss, and a stopped pass reporting every entry it
  never reached — so it cannot be mistaken for a finished one.
  **The gotcha that cost a round:** reading `InputStream.streamError` after a *successful*
  open segfaults in swift-corelibs-foundation. macOS was green and the whole Linux engine
  suite crashed at the first `Archive.create`. `streamStatus == .error` is the question
  anyway. And a permissions test is not portable to CI: the Linux container runs as **root**,
  where mode 0 stops nothing — the premise disappears rather than the assertion failing, so
  that one carries `.enabled(if: getuid() != 0)` and the portable half tests the hasher
  directly.
  **The hand-test needed a fixture nobody had built, and the two failures on the way to it
  are the record worth keeping.** `brctl evict` on a file *inside* a `.genea` crashes in
  CloudDocs — `BREvictItemAtURL` reads the item's ubiquity metadata, which is `nil` inside a
  package, and throws building an array from it: **per-file eviction inside a package is not
  available**, and `brctl status` takes a container zone rather than a folder. A *non-package*
  archive directory does give each file its own ubiquity identity, and that is what finally
  staged it: a 512 MB master, evicted, reading `size=536870912  blocks=0` with `SF_DATALESS`
  set — 57's measurement reproduced inside an archive — with `verify` printing `PARTIAL:` and
  naming it at 536.9 MB, and `--download-cloud-files` pulling it back to `OK:`. **Then the package case was measured, and it
  invalidates the slice's motivating scenario.** A package-born `.genea` has no per-file
  ubiquity identity inside it — `downloading`/`uploaded`/`uploading` all `nil`, against real
  values for the same files in a directory — because the *package* is the ubiquitous item:
  eviction is package-level, any access inside materializes the whole thing, and the inner
  files read fully present the instant they are visible. **`SF_DATALESS` never appears inside
  a `.genea` on iCloud, so the skip cannot fire there**; it covers archives kept as ordinary
  directories, and possibly per-file providers, still unmeasured. The near-miss worth
  recording: a directory *renamed* to `.genea` keeps its old per-file identity and does show
  dataless files — the convenient answer, and the wrong one. The invariant that survives is
  the one that never depended on the provider: **a report may not claim an assurance it did
  not pay for**, whatever made a file unreadable. What it opens is the same defect one level
  up — an un-downloaded archive downloads in full on open, before any check runs — which the
  package's own downloading status makes knowable in advance.
  869 engine tests on macOS (866 Linux), 158 CLI (Linux too), 81 app.
- **62 — a record survives any value the format allows.** The first slice of workstream
  (2)'s ladder, and test-only: a seeded SplitMix64 generator and per-type `Arbitrary`
  conformances in a new `GeneaLogicTestSupport` library target (not a product; Foundation +
  model only, so Linux builds it with everything else), and four properties over every
  persisted type — `decode(encode(v)) == v`, byte-stable re-encode, the pretty encoder
  agrees, and spec §3's *absent equals `null`*. **The format passed** — 200 iterations per
  type in CI and a 5,000-iteration soak found nothing to fix, which is the result, not the
  absence of one. **Two invariants the generator establishes**: an open-vocabulary value is
  built through `init(parsing:)`, never as `.unknown("vital")` by hand, so a generated
  value is always one a reader would produce — the only way `.unknown` can be generated
  without inventing a non-round-trippable case; and a generated value is a pure function
  of `(seed, iteration)`, with each iteration deriving its own generator, so a failure at
  iteration *n* reproduces with `GENEALOGIC_PROPERTY_ITERATIONS=n+1` and no replay of the
  ones before it. The generator is pinned against SplitMix64's *published* seed-0 vectors —
  an external reference — and one composed value is pinned on top, so a generator change is
  visible in review rather than silently moving every property. **Two spec corrections,
  recorded rather than built around:** `EmbeddedMetadata` is not persisted (extracted at
  attach, surfaced on `AttachedFile`, never written), so it has no conformance; and no
  persisted type has a floating-point field, so the encoder's `.throw` on non-finite is a
  direct test against a probe struct rather than a reachable property. **The gotcha:**
  null-injection is type-agnostic — every absent name from one global optional-key set
  becomes `null` in every object — which is safe *because* a required key is never absent
  and unknown keys are ignored, except inside `attributes`, whose keys are data; a `null`
  there is a malformed value, so the walk does not descend into it. And a property that
  injects nothing passes vacuously, so the injection has its own non-vacuity test.
  **`/code-review` found the sharper gotcha:** Swift `String ==` is *canonical equivalence* —
  `"é" == "e\u{301}"` is true — so a round-trip property compared with `==` cannot see an
  encoder or decoder that NFC-normalizes, which is the one thing the NFD string in the
  hostile list was there to catch. The walk over the hostile list now compares
  `unicodeScalars`, and it passes: the format stores what it was given. Two smaller ones
  fixed with it — a *thrown* encode/decode escaped the loop without the seed line and
  skipped the type's remaining iterations (now recorded per iteration like a mismatch), and
  an unparsable `GENEALOGIC_PROPERTY_*` fell back to the defaults, so a "reproduction" could
  silently be the default run (now a `preconditionFailure`).
  896 engine tests on macOS (893 Linux), CLI and app untouched.
- **63 — hostile bytes must not be a crash.** 55's five hand-picked shapes, made a
  property: every generated value (62's generator) is encoded and then damaged — truncated
  at every offset, bit-flipped, a key dropped or duplicated, a value retyped or nulled,
  nested 100,000 deep, made absurdly long, spliced with invalid UTF-8 — by a small
  ordered-JSON parser/emitter in `GeneaLogicTestSupport` (`JSONSerialization` can neither
  hold nor emit a duplicate key). **The oracle is not "decodes or throws"**, which is
  vacuous in Swift: it is no trap, a time limit, and *whatever decodes from garbage must
  satisfy 62's round-trip properties*. At the archive level the mutated sidecar goes in
  place, `.index/` is discarded, and the path must land in **exactly one** of indexed or
  reported. **The decoder passed** (2,000-iteration soak, both platforms; duplicate keys
  pinned first-wins on both). **The archive did not, twice — neither in the decoder.**
  First, before speccing: a `index.sqlite` with a valid header and corrupt pages passed
  `open` + `user_version` (both header-only) and the archive then *failed to open* from
  inside the in-place rebuild — 55's failure mode, one file over. `PRAGMA quick_check` on
  open now makes it an *unusable* file (recreate), ~0.3 ms/MB warm, measured before the
  decision rather than after it. Second, from the 1,000-iteration soak on macOS: one
  flipped bit turned a uid's `b65` into `B65`, and `fileExists(atPath:)` on APFS said the
  record *was* present under its own name — so its sole surviving copy was reported as a
  `.conflictingCopy`, with advice to delete it; Linux said `.misnamedRecord`. 50c's review
  bug, reopened by a case-insensitive filesystem: the presence test is now the directory
  listing under exact string equality, the rule the loader already applied. **Two more
  fixed on the way**: `sqlite3_bind_text(…, -1, …)` and `String(cString:)` both stop at
  the first NUL, so a place carrying `\u{0}` — legal since 62 — was indexed as 4 bytes of
  15 (confirmed failing before the fix); and a corrupt manifest's message was a
  `DecodingError` dump, now one line of plain words (`missing \`schemaVersion\``,
  `\`files[0].byteLength\` has the wrong type`) plus what is still true. **The gotcha:**
  the first cut of the sampled property cost 400 s CPU a run, all in *building* the
  unbounded mutants (a 1 MiB string, 10,000 copies) — which say the same thing at every
  site. They are now rare in the sample and exhaustive once; 50 s CPU, 4 s wall. And
  SQLite's `length()` on TEXT counts to the first NUL by definition — `length(CAST(v AS
  BLOB))` is the question. 941 engine tests on macOS (938 Linux), 158 CLI, 81 app.
- **64 — the version is archive-wide.** The format wrote `schemaVersion` in two places and
  read one; sync could make them disagree, and an older build then decoded a newer record
  with its unknown fields dropped and stamped it back down. **The decision** (settled before
  62, as a format decision): one version per archive, no forward compatibility, migration
  explicit — a build does not edit what it cannot fully understand; it says so at the
  door. Spec §8 rewritten with the two rejected alternatives and the expiry condition.
  **The invariant:** `open` and every mutation refuse a manifest newer than the build;
  the rebuild walk refuses a *record* newer than the manifest (the sync window — evidence
  the archive is newer, closed over a file it read perfectly, 55's one stated exception);
  a record *older* than the manifest is a straggler, skipped and reported with its own
  `reason` so Repair — one comparison — never offers a downgrade as a restore; a manifest
  older than the build throws `needsUpgrade` and `Archive.upgrade(at:)` / `genea upgrade`
  runs the (still empty) chain, testable now through an injected `Migration(steps:)`; the
  merge and every commit stamp the newer version, never a straggler's. Unparsable
  compares as newer. **Two departures from the spec text, both stated:** fork (e)'s
  column went in by `ALTER TABLE`, not a `schemaVersion` bump — 58's own note says a
  bump unlinks the database and every preserved copy with it, and the column is additive
  both ways; and the door is on `withState` too, because the app's handle is open for
  hours and a delivery in that time is the whole case. **The gotcha, from the review:**
  "record newer than the manifest" is the spec's phrase and the wrong comparison. The
  manifest is admitted only at or behind the build, and *behind* means a straggler
  manifest on an upgraded archive — so every record this build wrote was "ahead of the
  manifest", and the reconcile refused the archive's own records with *update
  GeneaLogic*; the next open demanded an upgrade that had already happened. The archive's
  version is what records are compared against: the build's on the walk, and on open,
  when the manifest is behind, the newest record stamp (one pass over the stamps, never
  on the common path — fork (c)'s own evidence, read the other way). Two smaller ones:
  a rebuild that throws inside `reconcileIfStale` skipped `noteReconcileOutcome`, so the
  app's 1 s poll would have walked every sidecar under the lock per tick until the
  manifest landed; and the hostile *record* property needed two new outcomes (refused;
  older-format). **And from the hand-test:** 59's carve-out in `rebaseline()` — leave a
  skipped record's entry alone, it proves a restore exact — swallowed the new reason too,
  so *Accept Current Contents* silently did nothing for a straggler's checksum finding.
  Every rule keyed on "skipped" had to be re-read against a reason that is not damage:
  Repair (refuse), the app's wording (intact), and rebaseline (accept). 972 engine tests
  on macOS (969 Linux), 162 CLI, 82 app.
- **65 — a write cut in half leaves one of two states.** `WriteCheckpoint` is an observer
  seam (never a thrower — a throw runs cleanup a crash doesn't) fired at every temp write,
  rename, move, unlink, SQL statement and marker transition; `WriteCutTests` copies the
  archive at each and opens the copy as the crash image, for 34 mutations. **The
  invariant:** every cut opens into the before or the after state, findings ⊆
  `.interruptedWrite` + `.unreferencedFile`, the flag set **iff** an `.interruptedWrite`
  exists, a second open agrees, `rebaseline()` leaves it clean. Exceptions, stated:
  multi-record writes (merge, revert, a verdict superseding another) land record-wise; a
  purge cut in half is less trash. **Fixes:** replace copies to a fresh path, never in
  place; stash writes `deletion.json` first; `restoreFile` writes the record first; purge
  drops the payload first; the crash-open reconciles `.trash/` against the sidecars; two
  more shapes read as `.interruptedWrite`; the flag is settled on open. **The gotcha the
  property found that the spec didn't:** open cleared the sentinel unconditionally, so a
  user who quit without *Accept Current Contents* was told on relaunch that the
  half-written record was corrupt — the marker now stays until `rebaseline()`. **Departures,
  stated:** the trash reconcile runs only on the open that found the sentinel (a sync
  delivery brings `.trash/` and `artifacts/` in any order); an entry the manifest *lacks*
  is not residue (unverified, not suspect — needed for *iff*); a delivery-covered path is
  ignored only while its bytes are the settled ones, so `abandonDelivery` still refuses
  half a commit of ours. Crash shapes in tests must come from the engine (a hand-edited
  manifest reads as a delivery). `scripts/kill-test.sh` is the out-of-process half.
  **From `/code-review`:** the verdict moved out of `dirty` into its own
  `.index/<machine>/interrupted` marker, so only the first open after a crash pays for
  the rebuild and the hash pass; a purge is now one rename to a hidden name, then the
  delete — payload-first (as specced) left a hollow `.file` entry indistinguishable from
  a record-only one; a stash whose move throws takes its record back out; `restoreFile`
  sidesteps strays on disk, since it now writes the record before moving; and the trash
  reconcile skips any subject a delivery is bringing — the sentinel says we crashed, not
  who wrote `.trash/`. The review's fixture found a pre-existing ABA in 50's merge (a
  record that returns to a superseded version reads as stale), spun off. **Hand-test
  passed** on copies of the real archive: the banner survives a reopen and *Accept Current
  Contents* clears it for good. 987 engine tests on macOS (984 Linux), 162 CLI, 82 app.
- **50e — a revert is not a stale manifest.** 50's merge keeps ours when the arriving
  entry is a version our writes replaced — read as *the sender never heard of our write*.
  A version can recur (⌘Z writes the exact snapshot back), and with the sender's manifest
  ahead of its record the merge decided against the version about to land; nothing
  revisited it, so the index served our edit for ever and `verify` called the reverted
  record corrupt. Found by 65's review fixture. **The decision:** the merge's ruling is
  provisional — `contested_file` (machine-local, additive, no format change) notes each
  delivered entry it overruled, kept-ours and 50b's drop alike, and when the overruled
  version is on disk the reconcile gate (open, and the poll) adopts *their* entry verbatim,
  re-walks the index and forgets the evidence. Nothing is minted, so 49's rule holds.
  **The invariant:** a note stands only while the manifest holds what the merge kept; our
  next write ends it, so a later landing is a reported conflict, never a silent loss.
  **The gotcha, from the rig:** tying the note to 50's catch-up proof (a delivered
  manifest naming our version) looked like tidy lifecycle and broke the slice — while any
  other delivery is in flight every open re-merges the manifest *we* wrote, which names
  ours by construction, so the note went before the record it waited for could land.
  **From `/code-review`:** the catch-up proof came back, guarded — the index remembers the
  digest of the manifest this machine last wrote, and only one from elsewhere proves a
  sender caught up (a note left standing would have adopted an out-of-band restore of the
  old bytes that 49 says to report); only a *record* triggers a reversal, hashed, and its
  payload contests travel with it (a payload answers by size alone, and a same-length one
  of ours read as theirs); open adopts through the poll's own reconcile, after 65's
  recovery and without a second walk; a failed adoption backs off. `deliver.sh` has a
  `revert` step. **Hand-test passed** in the app with the window held open across the
  landing. 997 engine tests on macOS (994 Linux), 162 CLI, 82 app.
- **66 — a rebuild agrees with the incremental path.** `RebuildAgreementTests` runs random
  sequences over every public mutation, 62's generated content, hostile transcript bytes and
  out-of-band damage with its repair, then holds the index against an in-place rebuild, a
  fresh one and the disk. **The invariant:** every index table is *derived* (re-derived
  byte-for-byte: `artifact`, `person`, `relationship`, `link`, `file`, `place`,
  `dismissal`, `unreadable_record`) or *memory* (untouched by a rebuild but for
  `orphaned_record`'s live uids), and a `sqlite_master` tripwire fails CI on a table that is
  neither; every `json` column is its sidecar's bytes. Rows compare as `typeof:hex` per
  column, so a column added later is compared without being listed. **The defect it found:**
  65's record-first reorder of `restoreFile` took the index upsert with it, ahead of the
  move, so a restored transcript's `search_text` was read off an empty path and its words
  went unsearchable until a rebuild; the upsert is now last (the index sits outside 65's
  crash argument — every cut rebuilds it). **The gotcha:** at even weights the undo paths
  landed 0–3 times a run, since each needs an earlier operation to leave it a token; they
  are weighted up, a step with nothing to act on re-picks, and the run fails if any
  operation never lands. Default 50 iterations (`PropertyRun.fromEnvironment(defaultIterations:)`);
  a 1,000-iteration soak found nothing more, and the real archive's app-maintained index
  matched a fresh rebuild row for row. **From `/code-review`:** the first upsert stays beside
  the record and a second follows the move, so a move that throws leaves the index agreeing
  with the record (the session carries on from that row); a refusal must be one the
  generator could not foresee — `recordDriftedOnDisk` only after damage — or the run fails;
  picks follow first-seen order, since a UUIDv7 minted in the same millisecond sorts by its
  random bits and the trash ties on a one-second `deletedAt`, so a seed did not replay its
  operations; the coverage check runs on the default seed only. It found `addArtifact`
  reusing an unreadable record's folder (slug unique against the index alone) — 58b.
  1,000 engine tests on macOS (997 Linux), 162 CLI.
- **58b — a new artifact must not take an unreadable record's folder.** `addArtifact` and
  `restoreFromTrash` make a slug unique against `takenArtifactSlugs` plus an `lstat` probe.
  **The invariant:** a new folder never takes a name the index holds, a preserved artifact
  record names (even with its folder gone — 59's repair writes back there), the manifest
  names (a delivery can land it before the folder), or anything occupies on disk; only
  `ENOENT` is free, any other probe error throws. **The exception that cost two rounds:** a
  restore ignores its record's *own* traces — copy by uid, index row by uid, manifest entry
  by checksum — since a delivered deletion leaves all three, and re-slugging stranded the
  record when the other machine's restore landed (`ManifestABATests`); the restore then drops
  every copy of its uid, whose repair offer would otherwise outlive it. **The review's
  scenario was half wrong:** since 59 `rebaseline()` keeps an undecodable record's entry, so
  a corrupt sidecar only refused the add; the overwrite was real for a blessed straggler.
  **Measured:** listing `artifacts/` cost ~8% of an add at 10,000 artifacts, so the disk is
  probed — a hand-made case-variant folder on a case-sensitive volume no longer blocks a
  name; the whole slice costs ~3 ms on a 162 ms add. 66's property never caught this: a
  drift refusal after damage passed from *any* operation; adds and restores may no longer be
  refused so, and `addArtifactOverDamage` lands it by default. 1,013 engine tests on macOS
  (1,010 Linux), 162 CLI.
- **58c — a deleted record keeps no preserved copy.** `rebuild` drops every copy whose path
  the manifest it was given no longer names and where nothing is on disk (`ENOTDIR`
  included; an unanswerable probe keeps it). **The invariant:** on disk a delivered deletion
  and a lost file look alike, but only a commit drops a manifest entry — so a lost record's
  entry must never be dropped by anything but a human. Hence three companions: the manifest
  recompute carries a record with a preserved copy (and its payload) like an unreadable one;
  `rebaseline()` keeps its entry (fork c, reversed by review — it is archive-wide); and the
  dirty-marker rebuild on open discards only the copies *it* staged for vanished files, so a
  removal cut before its commit still ends in the deletion while losses that predate the
  crash keep theirs. **The gotchas:** the first test showed a lost file kept its entry only
  until the next write (true on `main`: its `missingFile` silently vanished); and the first
  fix for the cut removal — no carry while any interrupted write was unresolved — let one
  died write cost every older loss its copy. The copy is the evidence, not "any vanished
  path": it exists only while the uid is live nowhere, so a hand-renamed folder still lets
  its old entry go. No schema bump — one would unlink every copy. 1,024 engine tests on
  macOS (1,021 Linux), 162 CLI.

- **58d — a vanished record can be restored.** `StandingFindings.vanished` names every copy
  whose path the manifest still names, whose file is gone and that no delivery in flight
  explains — exactly the `missingFile` findings `repairPlans` answers. The app pins them as
  "Missing record" rows (Restore inline, Delete in the context menu, no Reveal); the Verify
  Integrity panel offers both on any record row with a plan — the only app surface for
  relationships, links and dismissals — and `genea verify`/`genea repair --delete` give the CLI
  the pair. `RecordRepairPlan` carries the copy's own name, so a row says *whose* record, not
  `PER-0192…`. **The invariant:** deleting a missing record is restore-then-delete through the
  ordinary path (`deleteVanishedRecord`), so it is undoable by each kind's existing restore and
  an artifact lands in the Trash with everything left in its folder. **The gotchas:** the first
  version *discarded* the copy, and needed a guard against stranding an artifact's masters (the
  stray-file scan looks only in live artifacts' folders, so they would have been reported
  nowhere); `/code-review` showed that guard was the wrong shape twice over, and the hand-test
  then asked why the one delete in the app had no undo. Going through the ordinary delete
  answered both — dropping a copy can't be undone without minting a manifest entry for a file
  that isn't there. The banner needed `bannerFileDamage`: a vanished record is a standing
  finding before any sweep lands, and it fell through to "a change didn't finish". 1,038 engine
  tests on macOS (1,035 Linux), 166 CLI, 90 app.
- **67 — a scan survives its own ingest** (the exit review's hotfix). `ingestScanned`
  deleted a Continuity Camera capture as soon as `ingest`/`attach` returned — correct until 52
  made `mutate` enqueue-and-return, after which the engine found the file gone. The signatures
  never changed, so nothing failed to compile; 52's review found the three callers that *read*
  state after a write and missed this one, which only cleaned up. **The invariant:** a scan is
  deleted inside the write, and only once it has landed; a refused scan is kept and the error
  alert offers *Show in Finder*. Spec fork (b) had said delete anyway; `/code-review` reversed it
  — `archiveBusy` after five seconds makes a refusal transient, and a document scan can be many
  pages. The deletion is a scan-only wrapper over `ingest`/`attach`'s per-file loops, not a flag
  on them (a `true` passed for a dragged-in file would delete the user's original), and it owns
  the no-archive case `mutate`'s early return would skip. Each capture now has its own folder:
  the name has one-second resolution and the file now outlives the call. Review also found an
  older defect: an ingest whose file failed to attach left an artifact with no undo; it is now
  registered and selected. 96 app tests.
- **68 — the drift guard has no holes**. Conclusion removals unlinked without 58's
  check, so a delete destroyed a hand-edited or delivered record and its undo wrote back the
  index's stale copy; and an unresolved interrupted write switched the guard off archive-wide.
  **The invariants:** `removeAuthoredFile` refuses drift like `writeAuthoredJSON`; a cascade
  (merge, its revert, supersede, undismiss) goes through `applyCascade`, which pre-flights the
  lists it executes, because a refusal mid-cascade lands after writes and arms the interrupted
  flag; and the only exemption is **bytes we wrote** — `.index/dirty` is a write-ahead journal
  (`sha path` before each authored write, the path before each unlink), and recovery exempts a
  journaled path only while it holds those bytes. The first cut inferred the exemption from
  whatever differed from the manifest; `/code-review` showed that swept in every hand edit on
  disk at the crash, and everything since for a pre-68 marker (which now exempts nothing). A
  later write or removal of ours prunes the path. **Gotcha:** the hand-test's repeated `kill -9`s
  found a second crash before the first was accepted dropped the first's exemption — recovery
  now keeps the persisted ones as candidates. 1,053 engine tests on macOS (1,050 Linux), 166 CLI.
- **69 — preserved copies outlive the index**. 58's copy — sometimes a record's last —
  went with every recreation of the index (a bump, a corrupt file, a `quick_check` that merely
  failed to run), and crash recovery discarded the copy of every record lost in its window.
  **The invariants:** the index is never unlinked — a replaced file is moved aside under a
  pending name that every open carries (its `orphaned_record` *and* live rows, so a record
  unreadable at a bump keeps its copy too), and is deleted only once carried, else kept as
  `index-unreadable-*`; only `CORRUPT`/`NOTADB` is evidence, `BUSY`/`LOCKED` refuse the open,
  anything else is retried once before replacing; recovery discards only paths the journal says
  were unlinked (`removeArtifact` journals its record, a trash restore its bytes); every temp file
  is flushed (`F_BARRIERFSYNC` / `fsync`) before its rename — ordering, not last-write
  durability; `addPerson` 2.75 → 3.9 ms. **Gotchas (`/code-review`):** a carry tied to the open
  that moved the file stranded the copies when that open died; throwing on *every* probe
  failure made a persistent `IOERR`/`READONLY` unopenable for good; an `append` that answered
  `false` after a failed flush let `set()` truncate the journal. 1,069 engine tests on macOS
  (1,066 Linux), 166 CLI.
- **70 — a newer record is refused before its manifest**. With the manifest current and
  its witness matching, open reused the index, so a newer record delivered ahead of its manifest
  was never read: served as the old version, and reported by Verify as a size/checksum mismatch.
  **Measured first: no downgrade** (the drift guard and `rebaseline()`'s rebuild refused), so
  the defect was 64's promise, not the bytes. **The invariants:** open reads the stamps of the
  records that moved — no entry (when the manifest records sidecar checksums at all) or a
  different `st_size` — by `readdir`/`fstatat`, skipping dataless files: 53 ms at 30k records,
  where `FileManager` cost 3× and reading every stamp 11×. Everything that would write over or
  judge a record differing from its entry reads its stamp first and throws
  `archiveNewerThanBuild`: the drift guard, Verify, Repair, `removeArtifact`, `upgrade`.
  `verifyIntegrity()` now throws; the app's Verify panel shows the refusal. Accepted limit: a
  same-size newer record passes the open and is caught by its hash. **Gotchas (`/code-review`):**
  the guard returned before the stamp when a record had no baseline — the one real downgrade
  path; `removeArtifact` leaves by rename and never met the guard. The 1 Hz size sweep still calls
  a size-changed newer record a size mismatch — [#13](https://github.com/GeneaLogic/GeneaLogic/issues/13), parked until 1.1. 1,081 engine tests on
  macOS (1,078 Linux), 166 CLI, 96 app.
- **71 — three small ones**. **The blocked path:** the finding's fix (`isGone` in
  `deleteVanishedRecord`) was measured insufficient before speccing. Delete restores before it
  deletes, and Restore under a folder-turned-file failed with Foundation's raw Cocoa 516. **The
  invariant:** `restoreLocked` names a blocker (`recordPathBlocked`) before anything moves, and
  the plan deliberately does not look for one, so both ways out stay offered and say what to
  move. **The straggler wording:** the banner's wording is now `StandingDamageWording`, held by app tests, and
  damage is counted through `StandingFindings.undecodableRecords`, not the mixed list. **The parser detail,
  narrowed by measurement:** both platforms' parsers refuse an overflowing number at the root,
  and Linux attaches no parser error to *any* failure. So `debugDescription` is used only at a
  key; at the root it is always Foundation's boilerplate. **Gotchas (`/code-review`):** a
  dangling symlink in the folder's place slipped past `fileExists` and journaled a write
  before failing. The extracted wording could be built without the vanished-record merge the
  model did, so the merge moved inside it. 1,085 engine tests on macOS (1,082 Linux), 166 CLI,
  100 app.
- **72 — ROADMAP is direction** (docs only; opens workstream 3, *go public*). ROADMAP went
  from 7,199 lines to ~300: direction, *Now*, *Next*, *Later*, *Parked*. Every shipped spec
  moved verbatim to `docs/slices/` (one file per slice; phases 0–2 one file each), done by a
  script and checked two ways: every non-blank source line lands in some file, and
  every relative link and anchor in `docs/` resolves. **The invariant:** a slice's spec is
  `docs/slices/<n>-<kebab-title>.md`, written before it is built; status lives in ROADMAP's
  *Now* until slice 76, then in issues and milestones. **Phase numbers 4–6 keep their
  meaning** because ~10 code comments cite them; GEDCOM and AI are folded into app
  development by saying so, not by renumbering. **Gotchas:** a `### both edits…` line inside
  a code fence is not a heading, so the splitter tracks fences; and links between moved
  specs must be re-based *before* they are pointed at sibling files, or they gain a `../`.
  Comments that said "ROADMAP slice N" now say "slice N".
- **73 — a stranger can build it from the README** (docs and repo files; no code or format
  change). The repo gains `LICENSE` (Apache-2.0), `NOTICE`, `TRADEMARKS.md`, `README.md`,
  `CONTRIBUTING.md` (which absorbs `TESTING.md`'s durable parts; the per-slice checklists for
  slices 1–42 are dropped) and `SECURITY.md`. **The decisions:** the spec is CC-BY-4.0 with the
  attribution in its own header, which archives created from now on carry (older copies lack
  it, and NOTICE's statement covers them); the header also says the
  license covers the spec only, and GeneaLogic claims no rights in an archive's contents.
  Copyright is "The GeneaLogic Authors"; the unregistered mark is the maintainer's.
  Contributions come in under Apache §5, with no CLA or DCO. The format identifier and
  `.genea` are explicitly free for any conforming implementation.
  **Invariant:** `ReadmeExampleTests` runs the README's GeneaLogicKit example, and reads
  the README to check its code block still matches what the test runs.
  **Gotchas:** editing the spec's header is not a format change. Archives copy the spec at
  creation and checksum their own copy, so old archives keep their bytes. And **SwiftPM
  cannot depend by URL on a package in a subfolder**, so the README offers only a path
  dependency; a root manifest is filed for triage.
- **74 — the family is fictional** (tests, comments, docs, scripts; no behavior or format
  change). Every real person's names, the small towns, two street addresses and the
  archive's name are replaced across ~140 files by one fictional family (the cast table is
  in the spec), and Xcode's `Created by` headers are gone. The sample archive split off as
  74b. **The decision:** each replacement **carries the property of the name it replaced**
  (an initial `H` codes like `K` under D–M, so `Hanner` keeps the code of the `K` name it replaced), so the
  matcher's tests still assert what they did. Only three pins moved, all literal D–M
  codes, re-derived from the table. **Invariant:** `scripts/scrub-check.sh <list>` finds no
  denylisted name in the tree: one tokenizer for entries and text, so a phrase matches
  across a line wrap, and an allowed use is scoped to one file (`!TRADEMARKS.md:<name>`). The
  list stays outside the repo, because a list of real names would be the leak. It runs before 76's snapshot; CI can't run it.
  **Gotchas:** a plain `grep -w` misses a name inside `hannerAndHanaurShareACode` or a
  Swift `"\tHanner"`, so the replacement and the guard both split at camelCase humps. A
  blind lowercase replacement would have renamed a variable to `max`, shadowing Swift's
  `max()`, and rewritten the idiom "cry wolf". **And the guard's first run caught this
  entry and the script's own comment** using real names as examples: run it after writing
  the docs, not before.
- **74b — a stranger has something to open** (a new `GeneaLogicSample` library, `genea
  sample`, a welcome-screen button; no format change). **The decision:** one Swift builder,
  `SampleArchive.build(at:)`, writes the sample through the public API, so it moves with the
  format instead of being a frozen `.genea`; the app, the CLI, `make-demo-archive.sh` and a
  test all call it. Its nine page images are rendered from text by a committed macOS script
  and shipped as resources, so the engine only copies bytes and stays Linux-clean. The app
  keeps one copy in its container and reopens it as it stands. **Invariant:**
  `SampleArchiveTests` pins that the sample verifies clean and that every Review lane has
  something in it: eleven names to link (the 1920 census's six among them), one duplicate
  pair, one suggested relationship.
  It builds beside its target and renames into place, so a killed build never leaves a
  half-built sample where the app would open it. The spec's "ten people, three generations"
  became twelve and four: the first hand-run's Review led with three "No candidate" names
  (the groom's parents and the rabbi), so the parents became people and the rabbi's mention
  went. **Gotchas:** the scrub check caught two names *invented* for the manifest's other
  passengers, which were on the denylist: invented is not the same as safe. The check can't
  read Cyrillic, so the Russian page's names were checked by hand, transliterated. The
  README's screenshots are plain Markdown, light only: `<picture>` switched by theme on
  GitHub but showed nothing in previewers that strip HTML. **Gotchas
  (`/code-review`):** two windows racing lost in the *rename*, not the existence guard, so the
  loser showed an error; any failure with something now at the target is `alreadyExists`. A
  killed build left a hidden staging folder for good; the next build sweeps any older than an
  hour. 1,096 engine tests on macOS (1,093 Linux), 168 CLI, 104 app.
- **75 — the app is called GeneaLogic** (app only; no format change). **The decision:** only
  what a user sees changes. The product is `GeneaLogic.app`, bundle IDs
  `app.genealogic.GeneaLogic`/`…Tests`, document type `app.genealogic.archive`. The folder,
  project, target, scheme and `-DD` keep `GeneaLogicApp`, and `PRODUCT_MODULE_NAME` is pinned
  to it so `@testable import GeneaLogicApp` stands. No container migration: app-scoped
  bookmarks resolve only for the app that made them, so Recent starts empty once. The old type
  is dropped, not imported, because `.genea` is typed by its extension. **Invariant:**
  `ArchiveTypeTests` pins that `Info.plist`'s exported and opened types are the Swift `UTType`,
  read from `Bundle.main` (the test host is the app). **Gotchas:** every build still named
  `GeneaLogicApp.app`, wherever it sits, claims `.genea` under the old type; if it wins the
  lookup, the new app's open panels grey out every archive. The run-app skill unregisters all
  of them once, found in `lsregister -dump`, and matches processes by `/Contents/MacOS/GeneaLogic`
  so an old-name one shows. Spotlight's `mds` reports the old type until it restarts; Launch
  Services, which Finder uses, has the new one. **Gotchas (`/code-review`):** the first type
  test asked Launch Services, which answers for every bundle on the machine, so a stale build
  could fail it (and `UTType(filenameExtension:)` defaults to `.data`, which a package never
  is). Its other check compared a literal with itself. 106 app tests.
- **76 — the project is public** (docs, comments and GitHub; no format change). **The
  decisions:** `GeneaLogic/GeneaLogic` starts from a one-commit snapshot of this repo's `main`,
  and this repo stays private as the record. GitHub can't transfer an issue from a private repo
  to a public one, so the 13 open issues were re-filed in their old order as #1–#13, labelled
  by layer and kind, plus `parked`. A closed issue cited in code became the slice that fixed
  it; in docs, a short description. The exit review's table points at slices. Slices now land
  as PRs with a merge commit, and commits use a project address. **Invariant:** the tree has
  no URL into the private repo and, outside 76's spec, no issue number above #13; the private repo's owner is on
  the denylist, so `scrub-check.sh` holds the first. **Gotchas:** one issue's screenshot
  showed the real archive. Attachments are outside every check the tree has, so each was
  looked at. The author address is in every commit object, which a private repo never showed.
  Old and new numbers overlap (old #11 is closed, new #11 is open), so the rewrite was exact
  strings, never a blanket regex. The issues were filed before the tree was rewritten, to
  know their numbers.

- **77 — does DocumentGroup fit the engine?** (a prototype on `spike-77`, never merged; no
  format change). **The decision: no-go.** The app stays a `WindowGroup` on macOS 26.
  Slices 80 and 81 are dropped. The floor can still move to 27 for another reason. A
  read-only `DocumentGroup` viewer opened the archive cleanly: atime showed SwiftUI reads
  nothing inside the package, and `genea add` on an open archive caused no re-read or
  alert. Undo marking the viewer *Edited* was fixable with the model's own `UndoManager`,
  and that also settles slice 52's grouping trade-off. **What killed it:** File ▸ Save and
  ⌘S replace the whole package even for an unedited viewer, and neither
  `CommandGroup(replacing: .saveItem)`, AppKit menu pruning nor a blocking responder
  stops them. **Invariant:** the engine is the only thing that writes an archive, and
  nothing the app hosts may offer a save. **Gotchas:** a save stages a hard-linked
  sibling (`<name>.sb-…`) and swaps the tree in, so it copies no bytes and keeps file
  inodes (the open index survives). Writing *in place* into a staged file changes the
  original. `URLDocumentConfiguration.fileURL` is main-actor isolated, and
  `writer(configuration:)` runs off it; reading it there crashed. A change made in a
  `.task` isn't noticed until the next event. Background computer-use can't deliver
  keystrokes or a key window, so menu and typing checks need the app in front. The
  `xcode-27` runner label exists (preview) if CI ever needs it.
- **78 — split `ArchiveModel.swift` by domain** (app only; no format or behaviour change).
  **The decision:** `GeneaLogicApp/Model/` holds the class body (798 lines) and nine
  `extension ArchiveModel` files, from `+Trash` (81) to `+Artifacts` (895). The body keeps
  every stored property, because Swift allows none in an extension, grouped by domain
  under `MARK`s, plus loading, the write queue and the undo plumbing. `+Window` is the
  Mac-shaped part an iOS target would replace. **Invariants:** `+Window` holds triggers
  only; what happens to the data they bring lives in its domain file. A member is `private`
  unless another file uses it: 48 were widened, 21 of them the setters of observed state,
  and the app being one module means nothing stronger enforces the line. A separate model
  module waits for the iOS target. **Move check:** the old file's lines and the new files'
  lines are the same multiset, ignoring access modifiers, `MARK`s, braces and imports, apart
  from comments the move made wrong. No test changed. **Gotchas:** widening by name
  widened every overload, including private `pending:` ones used in one file, so the check
  is "used elsewhere", not "it compiles". `/code-review` found slice 67's keep-refused-scans
  rule in `+Window`, where an iOS port would have dropped it; moving it to `+Artifacts`
  re-privatized nine members.
- **79 — split `ArtifactDetailView.swift`** (app only; no format or behaviour change).
  **The decision:** `Views/ArtifactDetail/` holds a coordinator (278 lines: the loaded
  record, the sheets, menu commands) and a `View` type per section. Each section takes
  values and acts on the model itself, through the environment and `artifactID`, instead
  of the ~27 closures the coordinator rebuilt on every body run, which made every
  section unequal to its last self and so always redrawn. The five pieces of sheet state
  are one `ArtifactSheet` request behind one `.sheet(item:)`, reached by a binding.
  **Invariants:** a section's inputs are the values its body reads. State that only one
  section renders is read there: `capturedMetadata` in Embedded Metadata, `persons` in
  Persons Mentioned, which hands each row its one person. A row takes `isSelected` to read
  and the selection binding only to write. A menu command is refused while a sheet is
  up: one request means a new one would replace the open editor and drop its input.
  **Move check:** the first commit is a pure move. Its sorted lines match the old file once
  imports and access modifiers are stripped (ten types widened), apart from the
  file-level `MARK`s. **Not done:**
  `AssertionRow` still takes a delete closure (it is shared with People), so its rows
  redraw with their section. Nothing was measured; the boundaries are right by
  construction.

## Carryovers and parked work

*(Verbatim from the pre-split CLAUDE.md. ROADMAP's "Immediate next step" is the
authority on sequencing; these are the standing deferrals.)*

**Next in Phase 2:** no Vapor server yet. The lookup API is final; the SQLite index is a rebuildable cache, never
authoritative. Undo is **in-session only** (no persisted journal) and covers every mutation,
including new-artifact ingest (**Add Artifact**, renamed from Add Media in slice 35); the exceptions are
**artifact deletion (slice 20) and detached-file
deletion (slice 21), which are now also recoverable *across* sessions via the `.trash/`** —
narrow persisted-recovery carve-outs, not a general cross-session undo journal. The last planned
Phase 2 feature — Continuity Camera scan ingest — shipped in slice 23. Remaining
carryovers: a full persisted undo journal; and USB/network (ImageCaptureCore)
scanners, deferred from slice 23 as a possible follow-up. Sync/multi-writer follow-ups are
logged in ARCHITECTURE.md §10 (questions 4 & 5).

**Next up — Phase 3 (the conclusions UI).** Shape settled 2026-07; the build plan lives in
[`slices/phase-3.md`](slices/phase-3.md). Three decisions frame it: **manual-first**
(build create-person → resolve-mention → relationships → derived tree by hand; the
`GeneaLogicMatch` matcher + suggested-links queue + `mergePersons` come after, as a
mini-phase), a **section-switcher UI** (Artifacts / People / Tree over the one shared `ArchiveModel` —
implemented in slice 41 as a toolbar segmented `Picker`, *not* a window-level `TabView`, which broke the
split view's title/toggle/search; see the slice-41 entry), and **inspector-primary resolution** (turn a
`PersonMention` into a `Person` from the artifact inspector's Persons Mentioned section — **shipped in
slice 42** via the `ResolveMentionSheet` + resolved-mention chip). The engine write-path exists
(`addPerson`/`addRelationship`/`link`, tested); slice 40 is pure engine — public
`relationships(of:)`/`links(for:)` accessors + review-lifecycle mutations (`unlink`, `removePerson`,
`removeRelationship`, `updatePerson`), Linux-verified. Evidence stays separate from conclusions (§2.3):
a `PersonMention` is "the name as recorded here," never a tree identity. The person-side **Sources**
section **shipped in slice 42b** and **record-a-fact-from-linked-evidence** (human-confirmed, never auto —
§2.3, the conclusion-layer apply-suggestion flow) **shipped in slice 42c** — see both entries above.
Relationships (assert parent-child / couple, show relatives, remove) **shipped in slice 43**, bringing the
first Phase-3 **format change** — the *additive* `Relationship.facts` array (couple marriage/divorce,
`PersonFact` reused, no schema bump) + the resolved `person1`=parent convention (ARCHITECTURE §4.5).
Couple relationship **fact editing shipped in slice 43b** as a *unified Facts timeline* — a couple's
marriage/divorce is projected into each partner's Facts section (tagged "· with \<partner\>"), one
`FactEditorSheet` routing person vs. couple facts by type over `updateRelationship`; no format change —
see the slice-43b entry above. The **"Other person…" partner selector shipped in slice 43c** — record a
marriage with a not-yet-partner (or a brand-new spouse minted inline), name a spouse on a suggested
marriage, and pre-suggest the spouse from the source artifact, all app-layer over the landed engine
surface (see the slice-43c entry above). The **derived Tree tab shipped in slice 44** and
**parent-child qualifiers + siblings in 44f** — see both entries above. **CLI conclusions parity
shipped in slice 44b**, so the whole Phase-3 surface is now scriptable (and test archives are
seedable from a shell script rather than the GUI). 44b's /code-review also found a **shipped-app
data-integrity bug** — the app can re-mint a freed `PersonMention.localRef` that a surviving
`EvidenceLink` still claims, silently re-binding that citation to a different person — which is
now **slice 44c** (fix the app's mint, then consolidate the four format-level rules that have
drifted into two or three copies each into `GeneaLogicModel`). 44c, 44e
(`findDanglingReferences()` + the integrity-panel surfacing), 44g (repairing dangling references),
and **44d** (**CLI evidence-layer parity + read surface** — `event`/`place`/`show`/`set-role`/
`replace-file`/`lookup`/`relationship list`, the `set-meta`/`find` extensions, and the informational
dangling-refs sweep in `verify`; no engine change) have all shipped — see their entries above. The
44-series is complete through **44i** — **44h** was the matcher-precursor format revision
(mention-scoped `RecordedFact`s, source derivation, name language/script, open `PersonRole`, integer
scores; **§10.6 resolved**), and **44i** delivered the app surface over those fields *plus* an additive
`value`-field format revision (value-bearing facts — occupation, physical description — on both
`RecordedFact` and `PersonFact`; custom fact types; one-click Record; recorded-name capture). See the
44i entry above. **Next: the 45+ `GeneaLogicMatch` matcher mini-phase** — the format is now frozen for
the matcher, and a cross-person suggested-facts/links **triage inbox** was deferred there from 44i.
Its ladder is specced in [`slices/phase-3-matcher.md`](slices/phase-3-matcher.md) (45 scoring core → 45b candidate
generation → 45c review lifecycle → 45d CLI → 45e app inbox → 45f merge), framed by four forks
settled up front: suggestions are **ephemeral** (persisted only on confirm/reject, so
`.machineSuggested` becomes legal-but-unwritten), **Daitch–Mokotoff** is the first keyer rather
than Double Metaphone (the corpus is Ashkenazi/Slavic), the **CLI lands before the app** (inverting
44b/44d, because scoring needs a fast tuning loop against real data), and a confirmed suggestion
**stores the computed breakdown** rather than `link()`'s honest minimum.
