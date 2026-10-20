# 53 ✅ — the app joins the engine in Swift 6

**Problem.** The engine and CLI have been Swift 6 since they were written
(`swiftLanguageModes: [.v6]` in both manifests). The app is in the weakest of the three
available positions: `SWIFT_VERSION = 5.0` with **no** `SWIFT_STRICT_CONCURRENCY` (so it
defaults to `minimal`), while `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
`SWIFT_APPROACHABLE_CONCURRENCY = YES` are both on. It therefore pays every *cost* of the
Swift 6 model — unannotated code is implicitly `@MainActor`, and the whole approachable-
concurrency upcoming-feature set is enabled — and gets none of the *checking*. Slice 52
moved mutations off the main actor; the compiler is not currently verifying that they got
there safely.

**Layer.** App only (`GeneaLogicApp`). **No format change, no engine change.** Nothing in
the packages moves — they are already `.v6`.

**Measured before speccing** (2026-08-08, 73 files / 16k lines):

- `SWIFT_STRICT_CONCURRENCY=complete` in Swift 5 mode — **builds clean**, no errors, no
  warnings. That intermediate step is free and could ship on its own.
- Full Swift 6 mode — **6 errors and 26 concurrency diagnostics in exactly three files**:
  `ArchiveModel.swift` (30), `Views/PersonMentionEditorSheet.swift` (20),
  `Views/AssertionEditorSheet.swift` (6). The build initially reports **one** error,
  in `Support/PersonVocabulary+Display.swift`; the rest are behind it.

**The findings are real, which is the argument for the slice.** Every diagnostic sits in
code slice 52 moved off the main actor:

- **A genuine cross-actor read.** [`PersonMentionEditorSheet.swift:486`](../../GeneaLogicApp/GeneaLogicApp/Views/PersonMentionEditorSheet.swift:486)
  passes a closure to `updateMetadata`, whose `edit` parameter is `@escaping @Sendable` and
  runs inside `mutate`'s off-main work block ([`ArchiveModel.swift`](../../GeneaLogicApp/GeneaLogicApp/Model/ArchiveModel.swift)).
  It reads `name`/`role`/`quality`/`nameLanguage`/`nameScript` — all `@State` on the sheet —
  from a background thread while the user can still be typing into them. **This is slice
  51 fork (c)'s question from the other direction**, and it was not asked there: (c)
  established that a *refresh* cannot clobber view-local `@State`, not that a *mutation*
  cannot read it mid-edit. Modal sheet, short window, so benign in practice — but it is a
  real race the current settings hide. `AssertionEditorSheet` has the same shape.
- **The rest is mechanical:** `IngestOutcome` and `Self.defaultFileRole` are implicitly
  `@MainActor` and get captured into the `@Sendable` work closure; they are pure value
  types that want `nonisolated`. Likewise `prettifiedVocabularyLabel`, a pure
  `String → String` function that is main-actor-isolated only by module default — one
  word, and correct regardless of language mode.

**Design forks** (settled 2026-08-08):

- **(a) One hop or two? ✅ two, in one slice.** Land `SWIFT_STRICT_CONCURRENCY=complete`
  under Swift 5 first (measured clean — a verifiable no-op checkpoint), then flip
  `SWIFT_VERSION` to 6.0. Two commits, so a bisect can tell "the mode change broke it"
  from "the fix broke it".
- **(b) Fix the real race how? ✅ read the `@State` on the main actor and capture values.**
  Snapshot the fields into a `Sendable` value *before* handing the closure to
  `updateMetadata`, rather than annotating the capture away. `nonisolated(unsafe)` or a
  `@MainActor` closure would silence the diagnostic and keep the read; this removes it.
  **No `@preconcurrency` and no `nonisolated(unsafe)` anywhere in the slice** — the repo
  has zero of both today, and that is worth keeping as the reviewable property.
- **(c) `Archive`'s `@unchecked Sendable` — ✅ out, untouched.** It is in a package that is
  already Swift 6, so this slice does not reach it. Converting its `NSLock`s to
  `Synchronization.Mutex` for a *checked* conformance is a real idea and a separate one:
  it is the project's most safety-critical code, with lock ordering tuned by measurement
  across 47/51/52, and the payoff is a compiler-checked invariant rather than a bug fix.
  Not bundled here, not scheduled yet.

**Out of scope:** the toolchain bump (→ [54](54-the-linux-floor-moves-to-swift-6-3.md));
any behavior change; the `Mutex` conversion above; the deprecated `Text` `+` operator
warnings in `ArtifactListView.swift:215` (unrelated to concurrency — fold into a UI pass).

**Verification.**

- `xcodebuild … test` green, **including `GeneaLogicAppTests`** — the one part not yet
  measured: the numbers above come from `build`, so the test target has never been
  compiled in Swift 6 mode. Budget for unknowns there; if it is large, the test target
  flips in a follow-up rather than growing this slice.
- No Linux verification — app-only.
- **Hand-test:** the sheets whose closures change. Open the person-mention editor, type
  into the name field, save; edit an existing mention; do the same in the assertion
  editor. Then an undo/redo lap over both, since 52's undo behavior is the thing most
  likely to be disturbed by moving where the values are read.

**Shipped 2026-08-09**, in three commits rather than (a)'s two. **Fork (a)'s premise was
wrong**: `SWIFT_STRICT_CONCURRENCY=complete` under Swift 5 is *not* a clean no-op — it
surfaces ~40 warnings, being exactly the Swift 6 errors demoted. So the setting, the
fixes, and the mode flip each got a commit, which makes the flip itself the verifiable
no-op the slice wanted (zero errors, zero new warnings, 20 tests green). The real
cross-actor read was fixed per (b) by snapshotting on the main actor —
`PersonMentionEditorSheet.Edits`, plain locals in `AssertionEditorSheet` — and the repo
still contains **zero** `@preconcurrency` and **zero** `nonisolated(unsafe)`. The
unmeasured test target cost two diagnostics, not a follow-up slice: a non-`Sendable`
`ArchiveLock` captured into a `@Sendable` closure (the holder now opens its own from the
URL, so (c) holds and nothing in the package moved) and a `DispatchSemaphore.wait()` from
an async context. The two `Text` `+` deprecations are still there, still out of scope.
