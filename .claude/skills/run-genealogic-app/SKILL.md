---
name: run-genealogic-app
description: Build and launch the GeneaLogicApp Mac app to see a change running (not just tests). Use when asked to run, start, launch, or screenshot the GeneaLogic Mac app, or to confirm a UI change works in the real app. macOS only.
---

# Run the GeneaLogic Mac app

`GeneaLogicApp/` is a SwiftUI macOS app (a `WindowGroup` front-end over the
`GeneaLogicKit` engine, linked as a local Swift package). It targets **macOS 26.5**
with the **Xcode 26.5** toolchain. There is no `swift run` for it — it's an Xcode
project, so build it with `xcodebuild` and launch the `.app` bundle.

## Build

```bash
xcodebuild \
  -project GeneaLogicApp/GeneaLogicApp.xcodeproj \
  -scheme GeneaLogicApp \
  -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/GeneaLogicApp-DD \
  build
```

Expect `** BUILD SUCCEEDED **`. The build resolves the local `GeneaLogicKit`
package (plus swift-crypto) and codesigns with the App Sandbox entitlement.

> **Don't build to `/tmp`.** The app registers `.genea` as a document type, but
> LaunchServices flags apps in a temp directory `in-temp-dir` and refuses to use
> them as a document handler — so Finder double-click / `open file.genea` silently
> won't work (the *in-app* Open panel still does). A non-temp `-derivedDataPath`
> (as above) avoids this; building + launching once registers the handler.

> **ALWAYS pass `-derivedDataPath ~/Library/Developer/GeneaLogicApp-DD`. Never a bare
> `xcodebuild … build`.** Without the flag, the product lands in Xcode's *default*
> DerivedData (`~/Library/Developer/Xcode/DerivedData/GeneaLogicApp-<hash>/…`) — a
> **second `.app` with the same bundle id** (`app.genealogic.GeneaLogic`) at a
> different path. That's how you end up with two builds fighting: the last one built
> becomes the registered `.genea` handler, so `open some.genea` may launch a **stale**
> build (or a *second process*) while you think you're testing the fresh one — the exact
> trap that cost a debugging detour in slice 43c. The `-DD` path is stable (no hash), so
> always build **and** launch from it. (Building from the **Xcode GUI** also uses default
> DerivedData — fine on its own, but don't mix GUI builds with these CLI `-DD` builds in
> the same test session, or you reintroduce two same-bundle-id apps.)

### If the app shows stale behavior (two-builds troubleshooting)

Symptom: a change you just built doesn't appear, or `open file.genea` opens a window that
behaves like an older build. Almost always **two builds / two processes** with the same
bundle id. Diagnose and fix:

```bash
# Which build(s) are actually running? (look for >1 distinct .app path)
# The pattern matches the executable by prefix, so a pre-75 GeneaLogicApp shows too.
ps aux | grep '/Contents/MacOS/GeneaLogic' | grep -v grep

# Nuke everything, unregister and delete any stray default-DerivedData product,
# rebuild to -DD, relaunch:
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pkill -9 -f '/Contents/MacOS/GeneaLogic'
for app in ~/Library/Developer/Xcode/DerivedData/GeneaLogicApp-*/**/*.app(N); do $LSREG -u "$app"; done
rm -rf ~/Library/Developer/Xcode/DerivedData/GeneaLogicApp-*   # stray default builds
# …rebuild with the -derivedDataPath command above, then:
open ~/Library/Developer/GeneaLogicApp-DD/Build/Products/Debug/GeneaLogic.app
```

(The `(N)` glob is zsh's: no match expands to nothing. `rm -rf` alone leaves the
deleted app registered until Launch Services notices, so unregister first.)

The successful `xcodebuild` re-registers whatever it just built as the handler (watch for
the `lsregister … GeneaLogicApp-DD …` line at the end of the build log).

**Once, on a machine that built before slice 75:** the product was renamed from
`GeneaLogicApp.app` to `GeneaLogic.app`, together with the document type, so every build
still named `GeneaLogicApp.app` claims `.genea` under the old type. Wherever it is (`-DD`
Debug or Release, default DerivedData, a worktree's build, a copy in `/Applications`), it
can win the `.genea` lookup. Then Finder types archives as the old type, the new app's
open panels grey them out, and a double-click launches the stale app. Quit it,
unregister every one, and delete the build products:

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pkill -9 -f '/Contents/MacOS/GeneaLogicApp'
$LSREG -dump | sed -n 's#^path: *\(.*/GeneaLogicApp\.app\) (0x.*#\1#p' | sort -u |
  while read -r app; do $LSREG -u "$app"; done
find ~/Library/Developer -type d -name GeneaLogicApp.app -prune -exec rm -rf {} +
```

A copy outside `~/Library/Developer` (in `/Applications`, say) is unregistered but not
deleted; remove it by hand, or Launch Services registers it again when it next sees it.

### If a new app icon doesn't show

The icon lives in `GeneaLogicApp/GeneaLogicApp/AppIcon.icon` (Icon Composer). After
changing it, the Dock and About box can keep showing the old one even though the build
is right: macOS caches the icon per bundle path, and the `-DD` path never changes. Quit
the app, then:

```bash
APP=~/Library/Developer/GeneaLogicApp-DD/Build/Products/Debug/GeneaLogic.app
touch "$APP" "$APP/Contents/Info.plist"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open "$APP"
```

## Launch

```bash
open ~/Library/Developer/GeneaLogicApp-DD/Build/Products/Debug/GeneaLogic.app
```

The app opens to an empty-state window with **Open Archive…** / **New Archive…**.
Double-clicking a `.genea` in Finder (or `open some.genea`) opens it via
`onOpenURL`.

## Giving it data to browse

The app opens/creates `.genea` archive packages via the engine. To have something
to browse, make a test archive with the `genea` CLI first, then Open it in the app:

```bash
swift run --package-path GeneaLogicCLI genea create /tmp/Smoke.genea
swift run --package-path GeneaLogicCLI genea add /tmp/Smoke.genea \
  --title "1920 US Census – Smith" --source-tier census
```

## Live-verifying between runs

Computer-use needs `request_access` for `GeneaLogic` first. To pick up a rebuild,
**reset** the running app and reopen the archive:

```bash
pkill -9 -f '/Contents/MacOS/GeneaLogic'; open /tmp/X.genea
```

> `open X.genea` launches the **LaunchServices-registered handler** for `.genea`, which is
> whatever build registered last — *not* guaranteed to be your latest `-DD` build if a
> stray default-DerivedData build exists. To be certain you're running the fresh build,
> launch the `.app` explicitly first (`open ~/Library/Developer/GeneaLogicApp-DD/…app`)
> so that instance is running, or clear stray builds per the troubleshooting box above.

For anything that **mutates** (create/edit/delete/link), use a **throwaway** archive
(`genea create /tmp/X.genea`, add data in-app), and `rm -rf /tmp/X.genea` when done.

> **The user's real archive, if they have one, is named in `CLAUDE.local.md`** (untracked,
> per machine). It may be open or get restored on relaunch, often overlapping the test
> window (switch via the Window menu or ignore it). Open it **read-only** to spot-check
> regressions; **never mutate it.**

A restored/duplicate window can float small or toggle size on tab switches; option-click
the green button to maximize a test window for a clean screenshot, and zoom tight on the
region you're verifying.

## Driving file dialogs with computer-use

Which dialog you get — and whether automation can drive it — depends on where you
trigger it (this split landed in slice 4):

- **In-window `.fileImporter`** — **Add Media** (the `+` / ⌘I), **Attach File…**,
  and **Replace…** all present a SwiftUI `.fileImporter` (`[.item]`). These **are**
  screen-capturable and accept synthetic input, so computer-use *can* drive them:
  trigger the action → `cmd+shift+g` → type the file's full path → Return → Open.
- **Welcome-screen Open Archive** also uses `.fileImporter` (package-aware, filtered
  to `.genea`), drivable the same way.
- **File-menu Open Archive (⌘O) and New Archive (⌘N)** use AppKit `NSOpenPanel` /
  `NSSavePanel`, rendered out-of-process by **Powerbox**
  (`com.apple.appkit.xpc.openAndSavePanelService`), which is isolated from screen
  capture and synthetic input — computer-use **cannot** drive these.

So open + ingest + attach + replace + browse are fully drivable; only the
File-menu New/Open AppKit panels need a human — or seed an archive with the `genea`
CLI and open it from the shell (`open some.genea`, which routes through `onOpenURL`).

**SwiftUI gotcha (learned the hard way):** only **one** `.fileImporter` may be
live in a view hierarchy at a time — a second one (even on a different view) is
silently suppressed and never presents. The archive window therefore has a single
importer in `ArchiveContainerView`, shared by **Add Media**, **Attach File…**, and
**Replace…** via an `ArchiveModel.ImportMode` enum that `handleImport` switches on.
(Open Archive is *not* one of them — since slice 4 it lives on the welcome screen /
File menu, separately.) Don't add a second `.fileImporter`/`.fileExporter` alongside it.
