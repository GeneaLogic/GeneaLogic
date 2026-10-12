# Workstream (2) confirmation review — 67–71 (2026-10-09)

One `/code-review ultra` over the merged ladder (a draft PR in the private repo, `bb62330..5bb50e9`, 67 files /
4.6k lines in one pass). Its three findings came down to two defects, neither in the engine's recovery logic:

- **A second refused scan replaced the first's *Show in Finder* offer** (67). That offer is the only
  way back to a capture in a folder the user can't find. `keptScans` now accumulates until the
  alert is dismissed, and the alert composes its "kept" note from it, so a later, unrelated error
  can't drop it either. (The review's suggested fix, clearing on any other error, would have
  been the same loss by another route.)
- **`IndexDirtyMarker.append` read *any* failure to open the marker as "absent"** (69's own
  invariant, at the open rather than the write). Fixed by construction. No reachable case was
  found where the open fails but `set()`'s fresh write succeeds, so it has no test.
