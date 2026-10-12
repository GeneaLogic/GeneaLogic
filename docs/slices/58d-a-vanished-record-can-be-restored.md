# 58d — a vanished record can be restored ✅

Raised while speccing 58c (2026-10-03); specced 2026-10-03.

**Problem.** A record whose sidecar vanished (deleted in Finder, dropped by a sync) keeps its
preserved copy once a rebuild has run, and the manifest still names it — so 59's repair can
already put it back, byte-exact against the manifest (58c's CLI hand-test did). Nothing offers
it: `genea verify` asks for repair plans only on `unreadableRecord` lines, and the app shows
placeholder rows only for unreadable records, so in the lists a vanished record doesn't look
damaged — it looks absent, 56's problem again. And since 58c's review `rebaseline()` keeps a
lost record's entry, so `discardPreservedRecord` is the only way to accept the loss — and no
host calls it.

**Layer.** Engine (one field on `StandingFindings`, one on the repair plan), CLI, app. **No
format change**, no index table, no `user_version` bump. After 58c, which is what makes every
remaining copy a real loss rather than a deliberate deletion.

**Forks (settled 2026-10-03 — all as recommended, and (h) brought in rather than named as
58e):**

- **(a) The engine surface is `StandingFindings.vanished`** — paths with a preserved copy that
  the manifest names, whose file is gone (58c's `isGone`: `ENOENT`/`ENOTDIR`, never "cannot
  say"), and that neither a delivery in flight nor the interrupted-write evidence explains:
  exactly the copies `verifyIntegrity()` would report `missingFile`. **Recommend** the struct
  over a host join of the sweep's `missingFile` with `preservedRecordPaths()`: two hosts would
  re-derive the definition, and the app's sweep is async and coalesced. The cost is a handful
  of `lstat`s over a table that is normally empty, under the manifest read `standingFindings()`
  already does. The state is entered only through a rebuild, which moves `data_version`, so
  51's poll picks it up. Disjoint from `unreadable` by construction (a file that is there is
  unreadable or live). The type's "without reading a single file" becomes "without reading
  file contents".
- **(b) Only a vanished record *with a copy* gets a row.** Without one there is nothing to
  offer, Reveal would point at nothing, and 58c's residue drops its entry at the next write
  anyway; 57's banner already names the file. Also untouched: a sidecar gone with *no rebuild
  since* — its live row still shows it normally, so nothing looks absent.
- **(c) The row is 56/59's placeholder with a third condition**, "Missing record": pinned in
  the artifacts or persons list, Restore (always the plain one — nothing on disk to replace, so
  `requiresExplicitAcceptance` is false; an inexact copy still says so in the confirmation),
  **no Reveal in Finder** (nothing to reveal), and Discard (e). **As built, and kept on the
  hand-test (2026-10-04):** Restore is the row's one inline button; Discard is in its context
  menu and accessibility actions, and a visible button in the Verify Integrity panel. The
  irreversible action stays off the always-visible control, and a second inline button would
  crowd the name in a narrow sidebar.
- **(d) Name the record from its copy.** A missing person row labelled `PER-0192…` is useless
  for deciding between Restore and Discard, and here — unlike 56's case — the bytes decode.
  **Recommend** the engine put a `recordLabel: String?` (artifact title / person display name,
  decoded through `RepairTarget`) on `RecordRepairPlan`, the row preferring it over the
  path-derived label. Unreadable rows with a copy get the same improvement for free; `nil`
  (a copy this version can't decode) falls back to the path.
- **(e) Discard only on missing rows, never unreadable.** On an unreadable record the file is
  still there, its entry and finding stay, and discarding would only destroy the one good copy.
  Destructive confirmation, not on the undo stack (59's reasoning). **Settled differently once
  built:** this said an artifact's surviving files would then be reported unreferenced — they
  are not (the stray-file scan looks only in live artifacts' folders), so they would be
  untracked and reported nowhere. Discard is withheld while anything is left in the
  artifact's folder (`RecordRepairPlan.discardRefusal`), and the row says to restore it and
  then delete it. **Replaced on the hand-test (2026-10-04) by an undoable Delete:**
  `deleteVanishedRecord` restores the record from its copy and deletes it the ordinary way, so
  each kind's existing undo applies and an artifact goes to the Trash with everything left in
  its folder — which retires the "files left" refusal, the folder walk and `DiscardRefusal`.
  Still missing rows only: `recordNotMissing` when anything is at the path.
- **(f) CLI parity: `genea repair --record <path> --discard`**, refusing any path not in
  `vanished` (the engine call stays lenient; the CLI is where a typo'd path should fail).
  `genea verify`'s `missing-file` line names both commands when a copy exists — through the
  same `repairPlans` lookup as unreadable lines, held by the test that parses every suggested
  command. **Recommend** a flag over a new verb: it is the other answer to the same finding.
  **Became `--delete`** with (e); an artifact's line prints the `genea trash restore` that
  brings it back.
- **(g) The banner is unchanged.** 57's sweep already counts the vanished sidecar as a missing
  file and names it; the row is the new surface, and re-counting it as a record would say one
  loss twice.

- **(h) Relationships, links and dismissals get their Restore and Discard in the Verify
  Integrity panel** — they have no list, so no row, and 59 left their unreadable copies with
  no app surface at all. The rule is the panel's, not per kind: an `unreadableRecord` or
  `missingFile` row whose path has a repair plan offers **Restore…**, and a `missingFile` one
  also **Discard…**, with the row views' confirmations (named by `recordLabel` where there is
  one). Each action re-runs the check afterwards, as Rebuild Index and Accept Current Contents
  already do — a Discard changes other rows (an artifact's masters), so patching the list
  locally would be wrong. Artifacts and persons are offered there too; one rule is simpler than
  a kind filter, and the panel is where the CLI user's mental model already lives.

**Out of scope:** restoring a sidecar lost before any rebuild (b); a file-level Discard for
anything that is not a record with a copy (that is `rebaseline()`).

**Verification.** Engine (`VanishedRecordTests`): a Finder-deleted artifact sidecar and person
file, after a rebuild, are in `vanished` with a plan whose `recordLabel` is the title/name; an
unreadable record is not; a delivered deletion is not (58c prunes it); an awaited delivery and
a cut removal are not; restore clears it; discard clears it and the `missingFile` with it, and
an artifact's surviving master becomes `unreferencedFile`; `recordLabel` for each kind. CLI:
the hint line, `--discard`, its refusal on an unreadable path. App: row construction for the new
condition, discard through the model, and which panel rows carry which action (static, like
`IntegrityReportSectionTests`). Linux run. **Hand-test:** delete an artifact's `record.json`, a
person's file and a relationship's file in Finder, `genea reindex`, open the app — both rows
pinned and named, the relationship in the banner; Restore the artifact, Discard the person, and
Restore the relationship from Verify Integrity; the panel is clean afterwards.

**Shipped 2026-10-04** (merged); **hand-test passed** in the app. All eight forks as settled, (e) as amended above.
One departure: the banner needed `bannerFileDamage`. A vanished record is a standing finding
before any sweep has run, so the banner could be up with nothing in the file count and fell
through to "A change to this archive didn't finish"; the standing paths are now merged into
57's count (once the sweep lands it names them itself, so nothing is counted twice). CLI
hand-test run: a deleted person file and an artifact `record.json` (master left in place)
after `genea reindex` — `verify` names both by title, offers restore and discard for the
person, restore-then-remove for the artifact; `--discard` refuses the artifact and accepts the
person; restore is byte-identical; `verify` is OK.

**`/code-review` found ten things: nine fixed, one declined.**
The guard checked the files the *copy* lists, but a discard drops every manifest entry under
the folder, and a copy that won't decode listed nothing — so it failed open. It now reads the
folder itself (hidden files and empty subfolders aside), refusing when it can't. And the rule
lived only in the hosts, outside the write lock: `discardVanishedRecord` now re-derives the plan
under it and throws `recordNotDiscardable` with a typed `DiscardRefusal`, which both hosts word
from, so a refusal is said rather than swallowed and "0 of its files" can't be printed. Also
fixed: the panel's restore notice comes back through a callback rather than draining whatever
`actionInfo` was pending; the new `vanishedRecordPaths` overload is `restorableVanishedPaths`;
the row and panel share one set of strings and one action helper; a cut removal now has its
test. **Declined:** decoding each copy for its label on every refresh — the copies are only
the damaged records, a handful of small sidecars, and the folder check is one listing per
artifact copy, not a `stat` per master. 1,038 engine tests on macOS (1,035 Linux), 166
CLI, 89 app.

**The hand-test (2026-10-04) changed two things.** Discard could not be undone, which every
other delete in the app can — so it became **Delete**, implemented as restore-then-delete (fork
(e) above): two commits, a crash between them leaving the record restored. ⌘Z brings the record
back as a live one rather than as *missing* (that state was damage), and ⌘⇧Z deletes it again.
Restore stays off the undo stack: its inverse is re-creating damage, and Delete is the way back
from it. And the Verify Integrity panel now explains each record row the way the sidebar does
on hover — the copy's name and what the record's absence means — since the panel is where the
actions are visible. 1,038 engine tests on macOS (1,035 Linux), 166 CLI, 90 app.
