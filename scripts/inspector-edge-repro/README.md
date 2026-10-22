# Inspector edge repro (#9)

A minimal SwiftUI app showing the bug behind slice 80. An `.inspector` with
`inspectorColumnWidth` draws the toolbar's edge effect over its content only after
it has been hidden and shown again. At first appearance, content shows sharply under
the toolbar.

```bash
swift run --package-path scripts/inspector-edge-repro
```

Scroll the inspector, then click the Inspector button twice and scroll again.
Watch the text under the toolbar: sharp the first time, blurred the second. With
`INSPECTOR_WORKAROUND=1`, it is cut at the toolbar's lower edge both times. That is
the workaround in `ArtifactInspector`.

**When to drop the workaround:** when a plain run looks the same before and after a
hide and show. The Feedback number is on #9.

Not built by CI. macOS 26 or later.
