# Inspector edge repro (#9)

A minimal SwiftUI app showing the bug behind slice 80. Before macOS 27.2, an
`.inspector` with `inspectorColumnWidth` draws the toolbar's edge effect over its
content only after it has been hidden and shown again. At first appearance, content
shows sharply under the toolbar.

```bash
swift run --package-path scripts/inspector-edge-repro
```

Scroll the inspector, then click the Inspector button twice and scroll again.
Watch the text under the toolbar: sharp the first time, blurred the second. With
`INSPECTOR_WORKAROUND=1`, it is cut at the toolbar's lower edge both times. That is
the workaround in `ArtifactInspector`.

**Fixed in macOS 27.2** (FB25320177). The inspector now stops at the toolbar's lower
edge every time, with or without `inspectorColumnWidth`, as Preview's does. A plain run
and a workaround run look the same.

**When to drop the workaround:** when the floor reaches macOS 27.2. Until then it gives
earlier releases the look Apple settled on. Drop all three lines together
(`scrollEdgeEffectHidden`, `clipped`, `contentShape`), and this repro with them.

Not built by CI. macOS 26 or later.
