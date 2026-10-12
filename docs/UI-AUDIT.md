# GeneaLogic Mac App — UI Audit & Refinement Backlog

> Status: **✅ complete** (as of slice 39). A read-only triage of `GeneaLogicApp`'s UI
> surface (all 26 view/support files as of slice 23 / HEAD `d4950d5`), captured before the
> Phase 2 → Phase 3 transition. Goal: make the app **intuitive, Mac-like, and
> adherent to best practices**. **All findings F1–F14 are now worked** (slices 24–39;
> each entry below is annotated with the resolving slice); next is the Phase 3
> conclusions UI.

Each finding is tagged by category and carries a rough fix size:

- **[HIG]** — macOS Human Interface Guidelines (the "is this Mac-like?" lens)
- **[Idiom]** — SwiftUI best practice / code idiom
- **[UX]** — intuitiveness / discoverability

Severity tiers: **P1** (high impact), **P2** (medium), **P3** (polish).

The two P1s are the headline. **F1 is a quick isolated win.** **F2 is the strategic
paradigm call** that F3/F5/F8 hang off — decide F2's direction *before* polishing
those, to avoid refining a layout we may restructure.

---

## P1 — High impact

### F1. Sidebar rows lead with the raw UID — [HIG][UX] — *small* — **✅ (slice 25)**
`ArtifactRow` (`Views/ArtifactListView.swift:68`) shows `ART-0192f3…` in monospaced
caption under every title. This is the **primary navigation surface**, dominated by
developer-facing noise. It also contradicts the detail view's own stated philosophy —
UID is deliberately exiled to a de-emphasized "Identifiers" group at the bottom
*because* "they're not the first thing a researcher wants"
(`Views/ArtifactDetailView.swift:172`). Replace the subtitle with something meaningful:
media type · source tier · primary date · file count.

**Done (slice 25):** the subtitle is now `primary date (when present) · source tier · media
type` — blanks omitted, so a dateless artifact reads "compiled · image". The UID is gone from
the list. (Facets are easy to retune — tags or file count are candidates — but date + tier +
type proved the most useful general default.)

### F2. Detail view is a giant scrolling metadata stack; the document is secondary — [HIG][UX] — *large, strategic* — **Slice A ✅ (slice 24)**
For a **document-first** DAM, the natural Mac paradigm is **document-as-primary-content
+ metadata-as-inspector**. Today it's inverted: metadata fills the main pane in one long
`ScrollView` of six sections (`detailScroll`, `Views/ArtifactDetailView.swift:102`), and
the file preview is a *secondary* `HSplitView` that only appears once a file is clicked.
macOS 14+ offers `.inspector()` for exactly this — preview the artifact's primary file in
the main area, push metadata/events/persons into a trailing inspector. This is the biggest
"is this Mac-like?" question and reshapes F3/F5/F8, so it should be decided first.

**Status — staged:**
- **Slice A ✅ (slice 24):** the layout flip. Document fills the detail pane (primary-file
  preview + a multi-file selector strip + a no-files empty state); all metadata moved into a
  toggleable trailing `.inspector()`; Edit/Done preserved, now *inside* the inspector so the
  document stays visible while editing. Pure app-layer.
- **Slice B ✅ (= F3, slice 26):** the inspector's descriptive fields are now always-editable
  commit-on-blur, retiring the Edit/Done mode. See F3.

---

## P2 — Medium impact

### F3. Edit is a global Edit/Done mode, not live inline editing — [HIG] — *medium (tied to F2)* — **✅ (slice 26)**
The whole fields region swapped into a form on Edit. Mac inspectors (Finder Get Info,
Photos info panel) are *always editable* — no mode switch.

**Done (slice 26):** the Edit/Done mode is gone. The inspector's **Details** section
(`EditableArtifactFields`) shows the descriptive fields as live controls that **commit on
blur** (focus moving to another field) or on **Return**; the two pickers commit on change.
Each commit is its own undoable `updateMetadata` write, and only fires when the value
actually changed. The required **Title** reverts to the stored value if blurred empty. The
derived **Primary Date** stays read-only. External changes (undo/redo, an applied
suggestion) re-seed the live buffers via `onChange(of: artifact)`. Two deliberate shifts:
undo is now **per field** (not one "Edit Metadata" batch), and there's no Cancel — commit-
on-blur replaces it. **macOS note:** clicking an empty area doesn't resign a `TextField`'s
focus, so a commit lands when focus moves to another control or on Return — not on a stray
click in whitespace (verified live).

### F4. Welcome screen doesn't surface recent archives — [HIG][UX] — *medium* — **✅ (slice 33)**
`WelcomeView` is an icon + two buttons. Real Mac document apps (Xcode, Pages) open to a
*launcher* listing recent documents. The data already exists (`ArchiveBookmarks`, surfaced
only in File ▸ Open Recent). Add a recents list/gallery to the welcome window, and accept a
dragged `.genea` to open it.

**Done (slice 33):** a **Recent** section below the Open/New buttons — one row per bookmarked
archive (archivebox icon + name over its tilde-abbreviated containing folder, hover highlight),
height-capped at 5 rows and scrollable beyond, hidden entirely when there are no recents. Reads
the `@Observable` `ArchiveBookmarks.shared` so it updates live. Clicking a row **transforms this
welcome window in place** into the archive (the same `url`-binding write the Open/New buttons use)
after `ArchiveAccessStore.ensureAccess` re-derives the sandbox scope from the persisted bookmark;
a moved/deleted archive shows `ArchiveModel`'s existing "Couldn't Open Archive" state and the dead
bookmark self-prunes on the next launch (both verified live). Reopening a recent — from the welcome list
*or* File ▸ Open Recent — bumps it to the top (TextEdit-style) via a new bookmark-free
`ArchiveBookmarks.promote`, on a successful reopen only. A per-row context menu adds **Show in
Finder** and **Remove from Recents** (`ArchiveBookmarks.forget`). **Sandbox gotcha:**
`NSString.abbreviatingWithTildeInPath` keys off `NSHomeDirectory()`, which is the *container* path
in a sandboxed app, so it never abbreviates a real `/Users/<name>` path — resolve the true home via
`getpwuid(getuid()).pw_dir` instead. Pure app-layer, no engine change. **Deferred:** drag-a-`.genea`-
onto-the-welcome-window to open it (a distinct `.onDrop` mechanism, not needed for the recents win).

### F5. Sheets aren't resizable despite holding lists/editors — [HIG] — *small* — **✅ (slice 27)**
All four sheets were fixed-size (`.frame(width:460)`, `560×440`, `580×480`). The transcript
editor couldn't grow for a long transcript; the trash/integrity lists couldn't grow to show more
rows. Mac sheets with scrollable/editable content should be resizable.

**Done (slice 27):** `.presentationSizing(.fitted)` + a `min`/`ideal`/`max` content frame on each
sheet. **Key gotcha:** macOS 15 (Sequoia) made SwiftUI sheets fixed-size by default — a flexible
content frame alone changes only the *opening* size and adds **no drag-resize handle** (verified
live). `.fitted` is the documented opt-back-in to resizable sheets ([Apple DTS, forum
758456](https://developer.apple.com/forums/thread/758456)); no AppKit style-mask hack needed. The
three content-heavy sheets grow to screen (`max: .infinity`); the Assertion *form* resizes in
width only. The transcript `TextEditor` dropped its fixed `480×320` floor to fill the growable sheet.

### F6. Menu bar & keyboard affordances are thin — [HIG][UX] — *medium, sweep* — **✅ (menus slice 35; focus/keyboard slice 36)**
The app is heavily click-driven: most actions live only as in-pane buttons, with no
menu-bar presence and no shortcuts. This is both a discoverability gap (Mac users expect
to find — and learn shortcuts for — every action in the menu bar) and a keyboard gap.

> **Slice 35 shipped the menu-bar half:** a **View** menu (Show/Hide Inspector ⌘⌥I; Sort By =
> the F7 keys + per-key Ascending/Descending) and a top-level **Artifact** menu (Add Event/Place/
> Person, Edit Transcript, Attach File, a **Selected File ▸** submenu, and **Delete Artifact… ⌘⌫**),
> **Add Media → Add Artifact** renamed, **⌫ deletes the selected artifact** (`.onDeleteCommand`), and
> **window tabbing disabled** (it crashed on our value-based `WindowGroup` windows). Routed via
> read-only selection mirrors + one-shot intents on `ArchiveModel` (the menu `Commands` can't see the
> view-owned selection).
>
> **Slice 36 shipped the focus/keyboard half** (the two subsections below). Live testing found two of the
> three named gaps were **already framework-handled** — sheets auto-focus their first text control, and a
> focused multi-line `TextEditor` already treats Return as a newline. So the real work was: revealing the
> `AssertionRow` remove button on keyboard focus (it was `.opacity(0.55)`-until-hover, invisible to a
> Full-Keyboard-Access user), `.accessibilityLabel`s on the image-only controls (also **closing F11**), and
> moving the transcript Save to **⌘Return** (`.borderedProminent`) so plain Return stays the newline key.

**Menu bar — organization, missing actions, shortcuts.** Today: File has
New/Open/Open Recent/Add Media (⌘I)/Verify Integrity/Show Trash (`Commands/ArchiveCommands.swift`),
Edit gets only the free Undo/Redo/Cut/Copy/Paste, and there is no View or app-specific
(e.g. "Artifact") menu. Almost every artifact-scoped action is menu-invisible and
shortcut-less:
- **Not in any menu / no shortcut:** Add Event, Add Place, Add Person, Edit Metadata,
  Edit Transcript, Delete Artifact, Attach File, the per-file actions
  (Show Preview, Open in Default App, Save a Copy, Replace, Delete), Apply suggestion.
- **Wants a home:** a **View** menu for sort order (F7), the inspector/preview toggle (F2);
  an **Artifact** menu (or expanded File/Edit groups) gathering the artifact-scoped verbs;
  reconsider the `⌘I` = Add Media mapping (collides with the usual "Get Info").
- **Goal:** reorganize into coherent menus, surface the missing actions, and assign
  standard, non-conflicting keyboard shortcuts. (`@FocusedValue(\.archiveModel)` already
  routes File-menu actions to the key window — the same plumbing extends to these.)

**Focus traversal / Full Keyboard Access.** — **done (slice 36).** Full Keyboard Access already tabs
through the SwiftUI buttons once *System Settings ▸ Keyboard ▸ Keyboard navigation* is on, so the real
gap wasn't traversal but **visibility**: the `AssertionRow` remove button was `.opacity(0.55)` until
*hovered*, so a keyboard user landing on it (ring and all) couldn't see it. Fixed by revealing it on
`isHovering || removeFocused` via a per-row `@FocusState` (dim → full + focus ring on Tab, live-verified).
*Deliberately not done (per slice 34): rebuilding `List`-style arrow-key row navigation in the inspector
`ScrollView` — `List`-in-`ScrollView` is out, and FKA button-tabbing covers the need.*

**Other keyboard gaps:**
- ~~**⌫ doesn't delete the selected artifact**~~ — **done (slice 35):** `.onDeleteCommand` on the
  sidebar `List` raises the same confirm as the context-menu/⌘⌫ path.
- ~~**Sheets don't focus their first field**~~ — **already handled (verified slice 36):** macOS
  auto-focuses the first text control in a sheet — typing lands in Add Event's Event Type and the
  transcript editor's `TextEditor` with no click. No change needed.
- ~~**Transcript editor: Save is `.defaultAction` (Return)**~~ — **resolved (slice 36).** Live testing
  confirmed the focused multi-line `TextEditor` already consumes Return as a newline (Save's
  `.defaultAction` was merely *shadowed*, not misfiring). Save moved to
  **`.borderedProminent` + `.keyboardShortcut(.return, modifiers: .command)`** so ⌘Return commits while
  plain Return stays the newline key (Xcode commit-sheet precedent).

### F7. No sort control in the sidebar — [UX] — *small–medium* — **✅ (slice 28)**
Artifacts rendered in engine order with no way to sort by title / date-added / primary date.
A sort affordance is standard for a Mac list of this kind. Give it a home in the sidebar
control cluster proposed in **F14** (search + filter + sort together).

**Done (slice 28, with F14):** a **Sort** menu in the new sidebar `ListControlsBar`. Sorting is
client-side over the loaded summaries (`ArchiveModel.sortKey`/`sortAscending` → a `sorted(_:)` pass
in `displayedArtifacts`): **Title**, **Date Added** (by the time-ordered UUIDv7 `uid.raw`), **Primary
Date** (ISO string, undated artifacts last in both directions), with a stable title→uid tiebreak and
per-key direction labels ("A to Z", "Newest First", "Earliest First"). In-memory only (not restored);
default `.title` ascending = the prior order.

### F8. Inconsistent section affordances + hand-rolled rows — [Idiom][HIG] — *medium* — **✅ (slices 32 + 34)**
The "add" controls differ per section: Events/Places and Files use `Menu(.borderlessButton)`,
Persons uses a plain Button, Embedded-Metadata Apply uses `.buttonStyle(.link)`. And the
Events/Persons/Files rows are hand-built `VStack`s with custom hover backgrounds
(`AssertionRow`, `Views/ArtifactDetailView.swift:751`; `FileRow`, `:874`) that reimplement
what `List` gives for free (selection, hover, keyboard nav). Standardize the add-buttons and
consider `List`-based rows.
*Partly addressed (slice 32):* the Files section's add affordance was simplified (single
default role, no pre-pick) and each `FileRow` gained a **⋯ ▸ Role** editor.

**Done (slice 34):** the section-header add affordances are now one bright, leading-icon family from a
shared `AddAffordanceLabel` (icon + title, plus a trailing chevron when the control opens a menu).
Live inspection found four different looks, not the three the code review suggested — Events & Places
a `.borderlessButton` menu, Persons Mentioned and **Transcript** (unlisted here) bordered push
buttons, Files a dim borderless button. The lesson, over three visible brightness iterations: **don't
layer `.foregroundStyle` on a control style that imposes its own foreground** — `.borderless` /
`.borderlessButton` render the label *muted* (it read as **disabled**) and don't yield to `.primary`,
while `.menuStyle(.button)` renders bright, so any mix mismatched. The fix is the one style that
imposes no color — **`.buttonStyle(.plain)`** on all four (the Events `Menu` via `.menuStyle(.button)`
+ `.buttonStyle(.plain)`) — so the shared label's `.foregroundStyle(.primary)` is the single source of
appearance, and `.plain` renders the label faithfully so the label's own chevron shows on both
menu-poppers. That chevron distinguishes the two **menu-poppers** (Events "Add…", Files "Attach File…"
— which always pops the connected Attach / Import-from-iPhone menu) from the two **direct-action**
buttons (Add Person…, Add/Edit Transcript…); the Files chevron was the user's own ask. The
Embedded-Metadata **Apply…** stays a `.link` — it's a per-*row* action, a different control class from
the section-*add* controls, deliberately not folded in. The copy-pasted hand-rolled row chrome
(`AssertionRow`, `FileRow`, and slice 33's `RecentArchiveRow`) folded into one shared
`.hoverRowBackground(isHovering:isSelected:)` modifier.

**Reframe — the `List` migration is deliberately not taken.** Moving the hand-rolled rows to `List`
would fight the slice-24 document-first inspector, which is a `ScrollView` of stacked sections;
nesting `List`(s) inside a `ScrollView` is a SwiftUI anti-pattern (scroll-within-scroll,
indeterminate heights). The selection/keyboard-traversal `List` would have restored is **F6**'s job,
via `.focusable`/`@FocusState`, not `List`.

### F9. Duplicate window on relaunch — [UX] — *medium, bug (GH issue)*
Likely root cause: the value-based `WindowGroup(for: URL.self)` de-dups by `URL` *equality*,
so if the restored window's URL and the `open`/double-click URL differ by any normalization
(trailing slash, symlink resolution like `/Users/<name>` vs `/System/Volumes/Data/Users/<name>`,
percent-encoding), dedup fails and a second window appears (`Views/RootWindow.swift:34`). A
standardize-URL-before-`openWindow` step is the probable fix. **To be filed as a GH issue.**

### F14. List-scoping controls are split across the window — [HIG][UX] — *small–medium* — **✅ (slice 28)**
Search lived at the top of the sidebar (`.searchable(placement: .sidebar)`,
`Views/ArchiveContainerView.swift:138`) while the tag filter is a *trailing* toolbar menu
(`TagFilterMenu`, `:155`) — two controls that narrow the **same** artifact list, on opposite
sides of the window. They even AND-combine into one `ArtifactQuery`, yet they're visually
unrelated, weakening the "these shape the list" mental model (a user filtering by tag may not
connect the short list to a menu in the far corner). Best practice is to co-locate
list-scoping controls with the list they affect.

**Recommended:** keep search in the sidebar (the modern, correct placement — it belongs to
the list; toolbar search would render trailing, over the *detail*, even farther away) and
**bring the tag filter adjacent to it** — a filter button/menu beside or beneath the search
field atop the sidebar. Reserve the trailing toolbar for object/view-level actions (the `+`).
This also gives **sort** (F7) a natural home: search + filter + sort as one sidebar cluster.

**Stretch option:** fold tags into the search field itself as **search tokens / scopes**
(`searchScopes`, à la Mail/Notes) — the most unified pattern, but a larger interaction change;
noted for consideration, not necessarily this pass.

**Done (slice 28):** a `ListControlsBar` pinned under the search field via `.safeAreaInset(edge:
.top)` holds **Filter** (the relocated `TagFilterMenu`) + **Sort** (F7), `.bar` material + divider.
The trailing toolbar keeps only the `+`. The bar hides when the archive has zero artifacts but stays
when a filter yields no matches. Search tokens/scopes were **not** taken (the noted larger change).

---

## P3 — Low / polish

### F10. "Quick Look" menu item is mislabeled — [UX] — *trivial* — **✅ (slice 35, by removal)**
The FileRow ⋯ menu's "Quick Look" no longer invoked Quick Look (removed in the slow `.docx` preview fix); it just
re-selected the file for preview. Since the document-primary layout (slice 24) always previews the
selected file, selecting a row *is* previewing — so rather than rename it to "Show Preview", the
item was **removed** (along with the equally-redundant Artifact ▸ Selected File ▸ Show Preview).

### F11. VoiceOver labels on icon-only controls — [HIG] — *small, sweep* — **✅ (slice 36, with F6)**
The ⋯ menus and trash buttons relied on `.help()` tooltips (which VoiceOver doesn't read as a name).
Folded into slice 36: `.accessibilityLabel` on the image-only controls — `AssertionRow` trash → "Remove",
`FileRow` ⋯ → "File actions", the document-header pop-out → "Open in separate window" (the toolbar `+` and
the inspector `Label("Inspector", …)` already carry titles). *(A code-review nit fixed in the same pass: the
⋯ menu's `.help` was identical to its new label, doubling the VO announcement, so the tooltip was dropped —
the ellipsis is a conventional "more" affordance.)*

### F12. ISO-date free-text field has no validation feedback — [UX] — *small* — ✅ RESOLVED (slice 38)
Partly domain-justified (genealogy dates are often partial/approximate, so a `DatePicker`
doesn't fit), but a gentle "doesn't look like a date" hint would help
(`Views/AssertionEditorSheet.swift`).
**Resolved (slice 38):** the Add-Event Date field adopted **EDTF** and gained a live, non-blocking
gloss beneath it — "→ about 1920" (via `EDTFDate.humanDescription`, after shorthand normalization) when
the value parses, a gentle "Not a standard date — it'll be stored as text." when it doesn't. Add is never
disabled (genealogy must allow the unparseable). Paired with shorthand-acceptance — qualifier words
("abt 1920" → `1920~`), ranges, **month-name dates** ("June 1920", "April 3, 1975"), **decades** ("1940s"),
and lowercase masks ("192x") all normalize to canonical EDTF on commit — and human-readable rendering of stored dates across
event rows / Primary Date / the sidebar.

### F13. Magic-number content widths — [Idiom] — *trivial, code-quality* — ✅ RESOLVED (slice 39)
Scattered widths (560/640/420/460…) through the detail view; not user-visible.
**Resolved (slice 39):** the scattered content widths, sheet sizes, and small repeated chrome
(28pt hit area, 6pt corner radius, 20pt sheet inset) moved into one **`Support/Layout.swift`**
namespace of named constants (`fieldColumnMaxWidth`, `readableTextMaxWidth`, `iconButtonHitSize`,
`rowCornerRadius`, `sheetPadding`, and grouped `Layout.ContentSheet`/`FormSheet`/`PreviewWindow`
sizings). The three content-heavy sheets were unified to one size (their per-sheet drift was
incidental). Pure app-layer refactor.

---

## Suggested sequencing

1. **Decide F2** (inspector vs. keep scrolling-stack) — gates F3/F5/F8.
2. **F1** — quick, isolated, high-impact; independent of F2.
3. **F9** — file as a GH issue; investigate URL-normalization fix.
4. Remaining P2s, shaped by the F2 decision. Note **F6** (menus + focus traversal) is best
   done *after* F2/F7/F8 land, since its View/Artifact menu wants the inspector toggle (F2)
   and sort (F7). F6 now **owns** the focus-traversal work outright — slice 34 closed the
   `List`-based-rows route (inspector is a `ScrollView`), so F6 does it via `.focusable`.
5. P3 polish as a cleanup slice (can batch F10–F13).

Out of scope for this audit (tracked elsewhere): the deferred Phase 2 carryovers
(USB/ImageCaptureCore scanners, persisted undo journal, `findDanglingReferences()`), and
all Phase 3 conclusions work.
