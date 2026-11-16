# Inspector edge repro (#9)

A minimal SwiftUI app showing the bug behind slice 80. Before macOS 27.2.1, an
`.inspector` with `inspectorColumnWidth` draws the toolbar's edge effect over its
content only after it has been hidden and shown again. At first appearance, content
shows sharply under the toolbar.

```bash
swift run --package-path scripts/inspector-edge-repro
```

Before 27.2.1: scroll the inspector, then click the Inspector button twice and scroll
again. Watch the text under the toolbar: sharp the first time, blurred the second. With
`INSPECTOR_WORKAROUND=1`, it is cut at the toolbar's lower edge both times. That is
the workaround in `ArtifactInspector`.

**Fixed by macOS 27.2.1** (FB25320177). Content under the toolbar is blurred both
times. The blur is faint, and easiest to see while scrolling. `ArtifactInspector`
applies the workaround only before 27.2.1; it was not checked on earlier 27 releases.

**When to drop the workaround:** when the floor reaches macOS 27.2.1. Drop all three
lines together (`scrollEdgeEffectHidden`, `clipped`, `contentShape`), and this repro
with them.

Not built by CI. macOS 26 or later.
