# 54 ✅ — the Linux floor moves to Swift 6.3

**Problem.** CI and [`scripts/linux-test.sh:33`](../../scripts/linux-test.sh:33) both pin the
`swift:6.1` image, and that image — not the Mac toolchain, which is already 6.3.3 — is the
real floor for the engine and CLI. Everything worth adopting is 6.2+: `Span`,
`InlineArray`, strict memory safety, and the approachable-concurrency upcoming-feature
flags the *app* has been using all along but the packages cannot name. 6.1 also forces
`Package.swift`'s `.macOS("26.0")` string workaround, whose own comment
([Package.swift:16](../../GeneaLogicKit/Package.swift:16)) explains it exists only because
`.v26` does not exist in PackageDescription 6.1.

**Layer.** Build/CI, both packages. **No format change.** No source change is *required* —
this slice buys the option, it does not spend it.

**Design forks** (settled 2026-08-08):

- **(a) Which version? ✅ 6.3**, matching the Mac toolchain (6.3.3), so the two platforms
  stop drifting. Verify the `swift:6.3` tag exists before committing to it; fall back to
  6.2 if not, which still clears every feature named above.
- **(b) Raise `swift-tools-version` too? ✅ yes, and only then** — it is the change the
  image bump exists to enable. Both manifests go to 6.3, and `platforms:` becomes `.v26`,
  deleting the workaround comment. Do it in a second commit so a green CI run exists for
  the image bump alone.
- **(c) Adopt anything in the same slice? ✅ no.** Land the floor, keep the suites green,
  stop. Adopting `Span`/`InlineArray` in the engine is a performance change wanting its
  own measurement, and **strict memory safety is a decline, not a defer** — `CSQLite` is
  wall-to-wall unsafe interop and would bury the signal in noise.
- **(d) What about the app? ✅ unaffected.** It builds against the Xcode toolchain and
  never sees the Linux image. 53 and 54 are independent in both directions.

**The risk this slice is actually buying down, and its shape.** A newer image can *reject*
code the 6.1 compiler accepted — stricter diagnostics, a `Sendable` inference change, a
vendored-`sqlite3.c` warning that became an error. That is the whole reason to do it as a
slice with nothing else in it: if CI goes red, the diff is one line and the cause is not
in question.

**Out of scope:** adopting any 6.2+ API (→ later, per-feature); the app's language mode
(→ 53); bumping the vendored SQLite (`scripts/update-sqlite.sh`, unrelated cadence).

**Verification.** `scripts/linux-test.sh` for engine and CLI on the new image; the CI
Linux job green; macOS `swift test` for both packages unchanged; the app built once to
confirm the package change did not disturb it. **Nothing to hand-test** — if the suites
are green on both platforms this slice is done, which is what makes it safe to do alone.

**Shipped 2026-08-09.** `swift:6.3` is Swift 6.3.3, so it matches the Mac toolchain
exactly. The risk (a) named — a newer image rejecting code 6.1 accepted — did not
materialize: 634 engine + 139 CLI on Linux, 637 + 139 on macOS, 20 app tests, and a
from-scratch Linux engine build with **zero** warnings, vendored `sqlite3.c` included.
Both manifests are `swift-tools-version: 6.3` with `.macOS(.v26)` / `.iOS(.v26)`, and the
string-spelling comment is gone. Re-verified while there: `swift:6.3` still ships SQLite's
runtime `.so` and still no `sqlite3.h`, so the `CSQLite` vendoring decision stands — those
notes are now worded without an image tag rather than re-pinned.
