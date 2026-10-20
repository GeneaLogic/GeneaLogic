# 80 — Inspector and toolbar layering

**Problem.** ([#9](https://github.com/GeneaLogic/GeneaLogic/issues/9)) The artifact
inspector doesn't sit in the same place every time. When the artifact detail appears with
the inspector already shown, the inspector runs full height: its background fills the
toolbar band, and the toolbar's buttons float over it. After hiding and showing the
inspector, the reporter sees the other layout: the toolbar band runs across the inspector,
and the inspector starts below it, as in Preview.

**Layer.** App only, one view. No format change, no engine change.

## What is known

- **Where it is attached.** `.inspector(isPresented:)` sits on `ArtifactDocumentPane`,
  inside `ArtifactDetailView`, which is the detail column of the window's one
  `NavigationSplitView` (`OpenArchiveView.content`). Visibility is `@SceneStorage`,
  defaulting to shown.
- **Full height whenever the detail appears with the inspector presented.** That covers
  selecting the first artifact in a new window, a relaunch, and switching to another
  tab and back to Artifacts. Reproduced every time on macOS 27.0.1.
- **The "toolbar in front" layout is not reliably reproducible.** I saw it once in five
  hide/show cycles, in a 900×450 window. The reporter's two screenshots show it
  clearly. Its trigger isn't pinned down: maybe window size, maybe whether the inspector
  overflows and scrolls (the toolbar's scroll-edge effect).
- **Tried, with no change to the full-height first appearance** (scratch prototypes, not
  kept): presenting after appearance from a separate `@State`, both in `onAppear` and
  50 ms later, and wrapping the detail in a `NavigationStack`.
- **Untested on macOS 26**, the app's floor. This machine runs 27.

## Design forks

1. **Which layout is the target?** **Recommended: under the toolbar**, as in Preview. That
   is what the reporter expected, and the inspector belongs to the detail column, not the
   window. **Alternative: full height** (the macOS 26 style, as in Xcode). It is what
   appears today in the common case, so this fork may simply be "make it stay that way."
2. **How the slice runs.** The cause is SwiftUI's own placement, and the fixes that looked
   obvious didn't move it. **Recommended: a time-boxed prototype, as in 77.** Try, in
   order: (a) for under-toolbar, an explicit toolbar background over the window
   (`toolbarBackgroundVisibility(.visible, for: .windowToolbar)`) so the band is drawn
   the same way whatever the inspector does; (b) for full height, moving `.inspector`
   outside the `NavigationSplitView`, bound to "Artifacts tab and shown". (b) is the
   larger change, because the coordinator's state would have to move up to the window.
   Keep whichever is consistent across every case under *Verification*. If neither is,
   file Feedback with a minimal repro, write that up here, and close #9 as upstream.
   **Alternative:** go straight to Feedback without trying either.

## Out of scope

- **An empty glass capsule** sat in the toolbar beside **+** once, at 900×450, with the
  inspector shown. It may be the same layout bug. If it outlives this slice, it goes to
  the 81+ audit.
- **The window's default size** (900×450). It's already an 81+ candidate.

## Verification

No unit test: this is placement, which only shows on screen. **Hand-test** (yours, on
27, and on 26 if a machine is handy), in light and dark mode. Check that the inspector
sits the same way in each case:

1. A new window: select an artifact.
2. Hide and show the inspector from the toolbar, and from View ▸ Show Inspector.
3. Switch to People and back.
4. Quit and relaunch with the inspector shown (scene restoration).
5. A short window (inspector scrolls) and a tall one (it doesn't).
6. Open a sheet (Edit Transcript…), close it.

`xcodebuild test` stays green; nothing in the engine changes, so no Linux run.
