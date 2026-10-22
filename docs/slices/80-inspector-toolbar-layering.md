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

1. **Which layout is the target? Agreed: under the toolbar.** Full height depends on
   what is inspected. Xcode's inspector serves the whole workspace and follows the
   selection anywhere, so it gets a full-height column. Preview's and Pages' inspect the
   document in the content area, so they sit beside it under the toolbar. Ours describes
   the artifact shown in the detail column, so it belongs at that column's level. The
   code already says so: `.inspector` is on the detail column's content, which is the
   placement SwiftUI guidance gives for a split view, with the bar over the inspector.
   The full-height first appearance is SwiftUI not honouring that, not a second
   design.
2. **How the slice runs.** The cause is SwiftUI's own placement, and the fixes that looked
   obvious didn't move it. **Recommended: a time-boxed prototype, as in 77.** Try an
   explicit toolbar background over the window
   (`toolbarBackgroundVisibility(.visible, for: .windowToolbar)`), so the band is drawn
   the same way whatever the inspector does. Keep it if it is consistent across every
   case under *Verification*. If not, file Feedback with a minimal repro that says our
   placement is the documented one, write that up here, and close #9 as upstream.
   Moving `.inspector` outside the split view is ruled out by fork 1. **Alternative:** go
   straight to Feedback.

   **Outcome: a SwiftUI bug, worked around.** The toolbar background changed nothing.
   A minimal SwiftUI app with none of our code showed the cause, using one check:
   scroll the inspector and see whether its text shows sharp or blurred under the
   toolbar.

   - **By default the inspector never goes under the toolbar's edge.** Text shows sharp,
     with the inspector on the detail or on the split view, in either modifier order.
   - **`inspectorColumnWidth` changes that only on an animated re-show.** Text then
     blurs (the toolbar's edge), but never on first appearance. An in-code re-show with
     animation reproduces it, one without animation doesn't, and a very fast one left
     the inspector hidden while its state said shown. That is #9.
   - **Nothing reaches the first appearance.** That covers presenting late, a
     `NavigationStack`, toolbar items inside the inspector or removed altogether, and
     turning off AppKit's `allowsFullHeightLayout` on the inspector's split view item:
     SwiftUI keeps the setting off but ignores it.

   **Chosen: content never goes under the toolbar.** The inspector's scroll view sits
   in a container that respects the top safe area and clips
   (`VStack { … }.clipped()`), with the scroll view's own top edge effect hidden. So
   nothing is drawn under the toolbar for the bug to show sharp or blurred, and content
   stops at the toolbar's lower edge, as in Preview and Pages. `inspectorColumnWidth`
   stays, because it is the only thing that sets the column's resize range: without it
   the range shrank to a few points. Two rejected steps on the way:
   - **A hard top edge** (`scrollEdgeEffectStyle(.hard)`) drew a divider the rest of the
     toolbar doesn't have.
   - **A frame in place of `inspectorColumnWidth`** lost both the ideal width and the
     resize range.

   **Not fixed:** the column still runs full height behind the toolbar, and the empty
   band over it may differ slightly in tint after a re-show. #9 stays open for Apple's
   fix, with a Feedback report built from the minimal app.

## Out of scope

- **An empty glass capsule** sometimes sits in the toolbar beside the inspector button
  after a re-show. The minimal app shows it too, so it's SwiftUI's. It goes in the same
  Feedback report, not the 81+ audit.
- **The window's default size** (900×450). It's already an 81+ candidate.

## Verification

No unit test: this is placement, which only shows on screen. **Hand-test** (yours, on
27, and on 26 if a machine is handy), in light and dark mode. Check that the inspector
sits the same way in each case:

1. A new window: select an artifact.
2. Hide and show the inspector from the toolbar, and from View ▸ Show Inspector.
3. Switch to People and back.
4. Quit and relaunch with the inspector shown (scene restoration).
5. A short window (inspector scrolls) and a tall one (it doesn't). Scroll the
   inspector: its text stops at the toolbar's lower edge every time, with no divider.
6. Drag the inspector's edge: it resizes between 280 and 480 pt.
7. Open a sheet (Edit Transcript…), close it.

`xcodebuild test` stays green; nothing in the engine changes, so no Linux run.
