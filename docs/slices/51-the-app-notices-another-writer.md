# 51 ✅ — the app notices another writer

**Problem.** The app shows a stale list while an agent writes. Delete an artifact with
`genea` against an archive the app has open and nothing changes; `genea add` the same.
Rebuilding the index from the app appears to fix it — which is misleading, because the
rebuild is a no-op. **Measured, not assumed** (2026-08-07, off 47's hand-test): a
long-lived `Archive` handle sees another process's add *and* delete immediately, with no
reopen and no rebuild. `ArchiveModel.refresh()` already reloads everything correctly, and
`rebuildIndex()` calls it — that call is the only reason the manual rebuild helped.
**Nothing is broken except the absence of a trigger.**

**Layer.** App only (`GeneaLogicApp`). **No format change, and no engine change beyond a
one-line accessor** to expose the index's change counter — deliberately small, because the
work is a trigger, not a mechanism.

**Design forks** (settled 2026-08-07):

- **(a) How is external change detected? ✅ poll `PRAGMA data_version`** on a ~1s timer
  while the archive window is visible; if it moved, call `refresh()`. It is the primitive
  ARCHITECTURE §10.5 already names, it is **exact** — it bumps on other connections'
  commits and never on your own — and it costs one PRAGMA read. **Verified before
  choosing:** stable across no-op reads, bumps on an external `add`, on an external
  `person add` (which writes no manifest, so an `manifest.json` mtime check would have
  missed it), and on an external `reindex`. *Slice 49 retired the `person add` half of
  that — conclusion writes now do touch the manifest. **The choice stands unchanged**:
  the manifest's mtime also moves when we write it, so an mtime poller re-fires on the
  app's own edits, and an external `reindex` still moves the token while leaving the
  manifest alone. Both are pinned in `ExternalChangeTokenTests` rather than left as
  hand-verified notes.* FSEvents was the alternative; rejected *for
  now* because its only advantage is seeing out-of-band sidecar edits, which is slice 49's
  subject — adopting it here would pre-commit that decision from the cheaper side, the
  same argument that deferred WAL out of 47.
- **(b) What does a refresh do to the user? ✅ reload lists, preserve selection.** If the
  selected record was deleted externally, clear the detail pane rather than leaving a
  phantom selection.
- **(c) Defer refresh while an edit is in progress? ✅ no — it is unnecessary here.** The
  requirement was specced, then dropped on inspection: **every** in-progress edit in the
  app is view-local `@State` (the title/tags/notes fields, and all eight sheets, which are
  `@State`-presented and invisible to the model). `refresh()` only reassigns the
  `artifacts`/`persons` arrays, so it *cannot* discard any of it, and the detail pane's
  view identity is keyed on `selectedArtifact`, which (b) preserves. Building the
  deferral would mean plumbing an edit-depth counter through eight view-local sheet sites
  to guard against a hazard that does not exist. **If it ever does bite, that plumbing is
  the fix** — it is being skipped on evidence, not forgotten.

- **(d) Mutations block the main actor — ❌ moved out to [slice 52](52-mutations-off-the-main-actor.md).**
  Specced here, then split on measurement rather than taste: (a)–(c) came to one engine
  accessor and about forty lines of app, while (d) is a cross-cutting refactor of **54
  engine call sites and 17 `registerUndo` blocks** in a 2,800-line `@MainActor` model,
  with no shared mutation chokepoint to route through. That is ROADMAP's own two-slices
  test ("if the log entry won't fit in ~20 lines"), and bundling them would have held a
  working, verified fix hostage to a refactor. Nothing in (a)–(c) depends on it.

**Out of scope:**

- **Out-of-band sidecar edits** — a hand-edited `record.json` or one delivered by sync
  bumps no `data_version`, so this slice will not see it. → slice 49 (§10.4).
- **Merging concurrent edits**, and any "someone else changed this record while you were
  editing it" conflict UI. This slice makes the app *current*, not collaborative.
- **Cross-machine sync.** → 48–50.

**Verification.**

- Unit: the change-counter accessor; a poll that fires no refresh when nothing changed;
  selection preserved across a refresh, and cleared when the selected record is gone.
- No Linux verification needed — app-only, and the engine accessor is plain SQLite.
- **Hand-test (the one that motivated the slice):** open the app on an archive, run
  `genea add` and `genea remove` against it from a shell, and watch the list change with
  no menu command. Then type into a title field while an agent writes in a loop, and
  confirm the edit survives.
