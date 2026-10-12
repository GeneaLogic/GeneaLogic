# 41 — section-switcher restructure + People browse/create/delete

**41 — section-switcher restructure + People browse/create/delete ✅ (shipped, app):** the
Artifacts / People / Tree switcher — a **segmented `Picker` in the toolbar** over one
`NavigationSplitView` (Tree is a full-width `NavigationStack`), *not* a window-level
`TabView` (a top `TabView` displaces the split view's title/toggle/search; the
`.sidebarAdaptable` alternative nested split views and was crash-prone — both rejected
after live testing). Chrome preserved, the old single-archive layout intact in the
per-section `switch`, no regression; the People tab —
`PersonListView` (browse, search, ⌫/context delete + confirm), `NewPersonSheet`
(given/surname), read-only `PersonDetailView`; undoable `createPerson`/`deletePerson`
(in-session restore↔redelete, not trashed); auto-select of a new person; the
Artifact menu gates on the Artifacts tab being active. `TreeTab` is a placeholder.
No engine change (193/190 + 6 CLI unchanged); live-verified. **Editing split to 41b.**
