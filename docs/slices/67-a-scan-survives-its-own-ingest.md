# 67 — a scan survives its own ingest ✅

Specced 2026-10-04 from the [exit review](workstream-2-exit-review.md).

**Problem.** A Continuity Camera scan is deleted before the engine reads it: an empty artifact,
a "source not readable" error, and a capture that exists nowhere else. `ingestScanned` removes
the temp file as soon as `ingest`/`attach` return — and since 52 they only enqueue the write.

**Layer.** App only; no format change.

**Forks (settled 2026-10-04, as recommended):**

- **(a) The scan is removed inside the write closure**, on the write queue, once its file has
  been copied. Not in `commit`/`failure`: that is two copies of one cleanup and an extra hop for
  nothing the main actor needs. **As built:** not a flag on `ingest`/`attach` (a `true` passed
  for a user's own file would delete it) but a scan-only wrapper over their per-file loops.
- **(b) A failed scan is removed too.** Refusal is realistic (attaching to a drifted artifact),
  but the temp file is in a directory the user cannot find, so keeping it preserves nothing; the
  paper is still in hand. **Reversed on `/code-review` (2026-10-04):** a refusal can be
  transient — `archiveBusy` once another process holds the lock past five seconds — and a
  document scan may be many pages. A refused scan is **kept**, and the error alert offers *Show
  in Finder*; only a scan that landed is deleted.

**Out of scope:** the rest of the ladder.

**Verified by** `GeneaLogicAppTests` driving `ingestScanned` (made internal) for add, attach,
and a refused attach — the bytes land, and the temp file is gone only after the write. App
suite only; no engine change, no Linux. **Hand-test:** scan from an iPhone as a new artifact
and onto an existing one.

**Shipped 2026-10-04** (merged); **hand-test passed**, including a scan refused by the drift
guard being kept and shown in Finder. Fork (b) reversed as noted; the review's other findings
fixed on the branch (see SLICE-LOG).
