# 52 — mutations off the main actor ✅

**Problem.** Since 47 a mutation can wait on another process — up to `ArchiveLock.timeout`
(5s) for the flock, plus SQLite's matching busy timeout. `ArchiveModel` is `@MainActor`
and calls `addArtifact`/`addPerson` synchronously, so an agent looping `genea` beachballs
the app and then surfaces `archiveBusy`. Found by 47's `/code-review`, split out of 51 on
measurement (see that slice's fork (d)).

**Layer.** App **and one engine change** — see the scope amendment below. No format change.

**The 5s ceiling is not the bug and stays.** It is 47's fork (d), and shortening it would
spuriously fail legitimate contention on a large archive. The bug is that a *bounded wait*
is being done on the *main thread*.

**Scope amendment, agreed 2026-08-08 before building: the lock ordering had to change.**
The slice was specced as app-only on the grounds that `Archive` is already
`@unchecked Sendable`. Sendability was never the obstacle. `Archive.withState` took the
process-local `NSLock` **first** and then waited on the flock, and readers take that same
lock — so a writer waiting on another process parked every *read* too. Measured before
deciding: one `artifacts()` call on another thread cost **1.82s** while a competitor held
the archive. Moving the write to a background thread would therefore have relocated the
freeze to the app's next read (a detail-pane render, or 51's one-second poll), not removed
it — the slice could not have met its own verification criterion. The fix is a re-ordering,
not a redesign: a separate `writerLock` serializes this process's writers (keeping the
non-re-entrant flock safe), the flock is taken *outside* the state lock, and the state lock
covers only the body. Same measurement after: **0.5ms**. 47's timeout and `archiveBusy` are
untouched, so its fork (d) still stands.

**Design forks** (settled 2026-08-08):

- **Where does the boundary go? ✅ one `async` chokepoint on `ArchiveModel`** —
  `mutate(unopened:work:commit:failure:)`. `work` runs on a dedicated serial
  `DispatchQueue` (not the cooperative pool: a mutation can park a thread for 5s, and
  starving the pool would trade one hang for another); `commit` runs back on the main actor
  and is where undo registration and `bumpAndRefresh()` live. Reads stay on the main actor
  — after the engine change they no longer queue behind a writer, so moving them would buy
  nothing and cost every call site an `await`. **Everything one user action writes goes in
  a single `work`**, because `NSUndoManager` groups by run-loop turn and a hop per write
  would split one ⌘Z into several.
- **What happens to undo? ✅ register the counterpart synchronously, then mutate.**
  `NSUndoManager` files a registration by what it is doing *at the moment of the call*, so
  one issued after the `await` lands on the undo stack instead of the redo stack — ⌘Z
  becomes a one-way trip that redoes itself, silently. Five paths can't name their
  counterpart up front (the engine computes it: a fresh trash entry, a new `MergeDecision`,
  the removed record), so those register a *promise* on time and fill it in `commit`.
  The cost: a counterpart is on the stack even if the engine call then fails. Small, and
  the paths where failure is expected already no-op gracefully.
- **What does the user see while waiting? ✅ a delayed non-modal strip.** Nothing appears
  for the first 300ms, so an ordinary edit never flickers; `archiveBusy` still surfaces
  through the existing alert if the wait is exhausted.

**Out of scope:** the lock's *timeout* and `archiveBusy` itself (47); reloading on external
change (51, done). **Also left alone deliberately:** `Archive.open` still runs on the main
actor in `ArchiveModel.load()`, and it holds the flock across a possible index rebuild — so
opening a window can still block. That is window *setup*, not a user's mutation, and moving
it means designing a loading state for the window; noted here rather than smuggled in.

**Measured and *not* changed: `flock` has no fairness guarantee.** 52's review asked whether
the new ordering lets our reads starve a competing process, since a writer now holds the
machine-wide lock while blocked on the local one. It does not — four threads reading without
pause alongside a writer left a competitor's worst wait at ~20µs. What *does* starve a
competitor is a process that re-locks immediately after unlocking: a tight write loop failed
a competitor 5 times out of 5. **That is identical under both orderings** (measured), so it
is pre-existing rather than introduced here — it is the same unfairness `ArchiveLock.acquire`'s
backoff comment names, seen from the other side, and under 47's fork (d) "block, then fail
loudly" it is the designed outcome rather than a defect. No app path spins like that. A test
was written for it and then **deleted rather than shipped flaky**: at this granularity the
result is genuinely marginal, and a test that fails two runs in three would say less than
this paragraph. → revisit with the lock, in 47's territory, if a real workload ever hits it.

**Verification.** ✅ Engine: a read stays fast (0.5ms) behind a writer waiting on another
process, and concurrent in-process writers still serialize — both in
`CrossProcessWriteSafetyTests`, and the first fails at 29.8s without the re-ordering.
✅ App: **a new `GeneaLogicAppTests` target** (the app had none) — 15 undo/redo tests
across every mutation kind, plus 5 that hold the lock from "another process" and assert the
main actor stays free, the indicator's honesty, and `archiveBusy` arriving as a message.
Without the engine change the responsiveness test fails at **4.91s** for 50 main-actor
reads. CI's `mac-app` job now runs `test` rather than `build`. Every one of these was
checked by sabotage rather than assumed green — which is how two of them were caught
proving nothing (see the review pass below).
**Hand-test (owed):** run a `genea` write loop and use the app normally throughout.

**What `/code-review` found afterwards, and what it says about the shape of this slice.**
Every finding was in the same place: **a caller outside `ArchiveModel` that assumed the
write was synchronous.** Routing 54 sites through one chokepoint changed a contract those
sites never mentioned, and nothing failed loudly.

- Three callers keep their *own* copy of engine state, or tear down something a write
  needs: `TrashSheet` reloaded its lists in the same turn (so rows never left, and after
  Empty Trash it offered a Restore that could only throw), `IntegrityReportSheet` drained
  an `actionError` that was always `nil` yet and re-swept before the repair ran, and the
  archive window released its sandbox scope while a write could still be parked. All three
  now await a new `ArchiveModel.writesSettled()`.
- **Undo grouping: the review was right, the fix was worse, and the hand-test caught it.**
  Once registrations arrived a turn late, two actions whose commits drained in the same
  turn became one ⌘Z. Nesting can't help (`undo()` pops the whole top-level group), so
  grouping was made explicit and per-commit, with `groupsByEvent` switched off. **That
  broke renaming.** The manager is the *window's*, shared with AppKit's text-field undo,
  which registers typing steps against it — with event grouping off, a second ⌘Z after a
  rename landed on the text field's own entry and restored the typed text, reading exactly
  like a redo. **Reverted.** No automated test caught it because the model tests supply a
  bare `UndoManager` with no text field attached; only a human renaming something in the
  real window would see it.
  **So the merging case stands as a known limitation** — two *distinct* actions committing
  in one run-loop turn share a ⌘Z. Fixing it properly means giving the model its own undo
  stack, which also takes ⌘Z away from in-field typing: a UI decision, not a refactor, and
  one to settle before building rather than during. → its own slice if it ever bites.
  *(Worth noting the empty-group measurement even so, since it will matter to that slice:
  an explicit group with nothing in it is **not** discarded by `NSUndoManager`, so any
  per-commit grouping must open lazily on first registration or it will swallow the next
  ⌘Z after a write that registers nothing — emptying the trash, rebuilding the index.)*
- The undo before-snapshot was read at *enqueue* time rather than on the write queue.
  Fixed — reading it behind the serialization is plainly more correct and costs nothing.
  **Its observable symptom went away with the grouping revert**, though: under
  `groupsByEvent` two same-turn edits are one group, and undoing that group reaches the
  same end state either way. Kept as correctness, not as a bug fix, and left untested for
  that reason — the harness cannot express "two actions in one turn" at all.
- The wait indicator fired on elapsed time alone, so a long *local* write blamed a
  competitor that did not exist. `ArchiveLock` now reports genuine contention
  (`Archive.isWaitingForAnotherProcess`) and the bar asks it.
- **A failed write left the editor showing text the archive had rejected**, which looks
  saved. Took two passes. Refreshing the model on failure was not enough: a rejected write
  leaves the record *unchanged*, so the reloaded snapshot is `Equatable`-identical and the
  editor — which re-seeds on the record changing — never hears about it. The model now
  bumps a `writeFailures` counter that editors key on directly. Verified in the running
  app: the field snaps back to the stored title as the alert appears. (The alert itself is
  correct, not a bug — the timeout is 5s, so any hold longer than that fails the write.)
- **"Closing the window loses a write" did not reproduce.** Worth recording, because the
  slice's own hand-test predicted it and the first attempt appeared to confirm it. Running
  the *control* — same edit, same contention, window left **open** — lost the write too, so
  closing was never the variable: both runs simply outlived the 5s timeout. A write issued
  with no competitor and the window closed immediately lands fine, which is the case the
  `writesSettled()` guard on scope release was actually for.
  What is real, and narrow: **a write that fails after its window is gone reports nothing**,
  because the alert has nowhere to present. The edit is not silently corrupted — it did not
  happen, exactly as with the window open — but the user is not told. Fixing it means an
  app-level error surface that outlives a window, which is a design question rather than a
  bug fix. → follow-up.
- **A focused text field silently ate the second ⌘Z** — the last bug, and the one that
  needed driving the real app to find. Undo a rename twice and the second press did
  nothing; Edit ▸ Undo had lost its action name, which is the tell: something had pushed a
  *nameless* step. It was AppKit. A focused `TextField` has a live field editor that
  registers its own undo step against the window's manager when the text is replaced
  programmatically — and the re-seed after an undo does exactly that. Synchronously (pre-52)
  that step landed inside `undo()` and was filed harmlessly as a redo; awaited, it arrives a
  turn later with `isUndoing` false and lands on the *undo* stack. The same "a turn late"
  mechanism as the rest of this pass, but the registration is AppKit's, not ours.
  `ArtifactDetailView` now releases focus when the re-seed overwrites the field the user is
  in — and only then, so committing an edit and tabbing on doesn't move focus underneath
  them. Verified end to end in the running app: T2 → T1 → R1 → T1 → T2 with the field
  focused throughout.
  **No automated test covers it, and none can at this layer** — it needs a real field
  editor attached to a real window. It is the second finding in this slice that only a
  human at the keyboard could reach (see the grouping revert above), which is the argument
  for the hand-test rather than an argument for more unit tests.
