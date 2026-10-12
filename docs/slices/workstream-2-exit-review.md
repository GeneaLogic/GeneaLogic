# Workstream (2) exit review — findings (2026-10-04)

A data-loss review before leaving the workstream: an inventory of every path that deletes,
overwrites or moves archive bytes, plus cloud reviews of 62–63, 64–65 and 58b–58d (50e + 66
were not reviewed). Each finding was re-checked against `main` at `bb62330`. The issues were
the record (in the private repo; 76 re-filed the open ones); the ladder below (agreed 2026-10-04) is how they are worked.

| Worked in | Finding | Kind |
| --- | --- | --- |
| [67](67-a-scan-survives-its-own-ingest.md) | Continuity Camera scans deleted before ingest (52 regression; confirmed in the app) | bug — hotfix |
| [68](68-the-drift-guard-has-no-holes.md) | Deleting a conclusion skips the drift guard; undo restores the stale copy | bug |
| [69](69-preserved-copies-outlive-the-index.md) | Preserved copies destroyed by three paths (inconclusive `quick_check`, over-broad recovery discard, any index unlink) | bug |
| [68](68-the-drift-guard-has-no-holes.md) | Drift guard off archive-wide while an interrupted write is unresolved | bug |
| [70](70-a-newer-record-is-refused-before-its-manifest.md) | Newer-format record arriving before its manifest is skipped, not refused | bug |
| [69](69-preserved-copies-outlive-the-index.md) | No `fsync` — power loss can empty a sidecar (compounds the preserved-copies finding) | decision |
| [#10](https://github.com/GeneaLogic/GeneaLogic/issues/10) | Replace File loses the prior master after quit | decision |
| [#11](https://github.com/GeneaLogic/GeneaLogic/issues/11) | Deleted conclusions have no cross-session trash | decision |
| [71](71-three-small-ones.md) | Delete offered for a missing record, then refused (ENOTDIR) | small bug |
| [71](71-three-small-ones.md) | Damage banner reads older-format stragglers as crash residue | small bug |
| [71](71-three-small-ones.md) | Corrupt-manifest errors drop the decoder's `debugDescription` | small bug |
| [#12](https://github.com/GeneaLogic/GeneaLogic/issues/12) | Migration steps need a re-run/backup contract before the first one | latent |

**The ladder (2026-10-04).** Each is specced here before it is built.

| Slice | Layer |
| --- | --- |
| [**67**](67-a-scan-survives-its-own-ingest.md) ✅ — a scan survives its own ingest | app (hotfix) |
| [**68**](68-the-drift-guard-has-no-holes.md) ✅ — the drift guard has no holes | engine |
| [**69**](69-preserved-copies-outlive-the-index.md) ✅ — preserved copies outlive the index | engine |
| [**70**](70-a-newer-record-is-refused-before-its-manifest.md) ✅ — a newer record is refused before its manifest | engine |
| [**71**](71-three-small-ones.md) ✅ — three small ones | engine + app |

**Deferred:** [#10](https://github.com/GeneaLogic/GeneaLogic/issues/10) and [#11](https://github.com/GeneaLogic/GeneaLogic/issues/11) are trash-backed answers that would widen `TrashEntry.kind` (a
format change, beside [#2](https://github.com/GeneaLogic/GeneaLogic/issues/2)); [#12](https://github.com/GeneaLogic/GeneaLogic/issues/12) belongs to the slice that lands the first migration step.
[#13](https://github.com/GeneaLogic/GeneaLogic/issues/13) (found in 70's hand-test: the size sweep's banner calls a newer record a size mismatch) is
parked until 1.1 exists — until then no archive can reach it, and every action from the banner
already refuses correctly.
