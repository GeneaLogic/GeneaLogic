# 50e — a revert is not a stale manifest ✅

**Problem.** 50's merge keeps **our** entry when the arriving manifest names a version our
own writes replaced — read as proof the sender never heard of our write. A version can
**recur**, though: edit a record here, let the other machine take the edit, undo it there
(⌘Z writes the exact snapshot back), and the other machine's record is byte-identical to
the one we replaced. If its manifest lands before its record — the ordinary in-flight
window — the merge keeps ours and settles the witness; when the record lands, nothing
re-runs (the witness gate is `manifest.json` alone), so the index serves our edit for ever
and `verify` reports the reverted record as **corrupt**. Reproduced in a test on `main`
2026-10-01 (found by 65's review fixture). Record-first delivery is already right; this is
the manifest-first order only. The **drop** half of the rule (50b) has the same shape: a
record we deleted that the other machine restored from the trash lands invisible.

**Layer.** Engine only. **No format change** — one machine-local table in `.index/`, like
`superseded_file`; lost with the database, after which the merge behaves as it does today.

**The insight.** The two manifests cannot tell *never heard* from *heard and reverted*,
but the **disk eventually can**: in 50's case the sender's record never arrives (it did
not write it), in this one it does. So the merge's decision against a delivered entry is
**provisional** — kept until the version it overruled shows up on disk.

**Design forks** (settled with the user 2026-10-01, all as recommended):

- **(a) How to break the tie — recommend: remember the override, revisit when theirs
  lands.** When the merge keeps ours (or drops the entry) against a delivered entry, it
  notes *path, their entry, our entry*. When the disk at that path later holds **their**
  version, the decision was wrong: their entry is adopted into the manifest (an entry
  *they authored* — nothing minted, so 49's laundering rule still holds by construction),
  the index is rebuilt, and the note goes. Rejected: **write-unique records** (a per-write
  nonce so no version can recur) — a format change to every record type that also ends
  byte-identical undo; **timestamps** (their manifest's `updatedAt` against when we
  superseded) — cross-machine clocks.
- **(b) Scope — recommend both halves.** The substitute (kept ours) and the drop (50b's
  deleted path) are one decision point and one note; the drop's landing is a record that
  is back on disk.
- **(c) When a note stops standing — recommend: the moment our manifest entry is no longer
  the one the merge kept.** A later local write to the path, or another delivery that
  moves the entry, drops it. Keeping it would let a landing of theirs *after* our next
  edit silently replace that edit — the provider ate one side of a real conflict, which
  must stay reported (50's out-of-scope case), not be adopted.
- **(d) Where the revisit runs — recommend the reconcile gate** (open, and the app's 1 s
  poll): one indexed read, empty on nearly every archive; per standing note one `stat`,
  and one hash of a small sidecar only when the size already matches theirs (payload by
  size alone, 57's rule). Open-only would leave a window stale for as long as it is open.

**Out of scope:** a provider that ate one side of a same-record conflict (unchanged — still
reported, see (c)); retention for `superseded_file` (unchanged); a delivery landing while
the index is recreated (degrades to today's behaviour, stated).

**How it will be verified.** Engine: the reproduction (manifest first, then the record →
adopted, verify clean, editable); record-first pinned; 50's own case unaffected — the note
stands while the disk holds ours, and nothing is adopted; a local write after the merge
drops the note, so a later landing of theirs is *reported*, not adopted; the drop half (a
restore landing after its manifest); convergence (a second reconcile writes nothing);
laundering (the adopted entry is theirs verbatim, and rot elsewhere is still reported);
the note's lifecycle. Linux via `scripts/linux-test.sh`. **Hand-test:** `scripts/deliver.sh`
grows a `revert` step (edit on mine, take it on other, undo it there); step `manifest`
then `record` with mine open in the app — the person shows the reverted version once the
record lands, with no banner.

**Shipped as specced**, every fork as settled. **Hand-test passed** (2026-10-01): the app
half, on `deliver.sh setup → revert → manifest → record` over a demo archive — mid-flight the
window showed mine's edit and one finding (the setup's person, still arriving); once the
record landed the revert replaced the edit, the arriving person appeared, and the finding
cleared with no banner, all without reopening. The engine half (`deliver.sh setup → revert → manifest → record`, read with `genea`) passed
2026-10-01 — mine keeps its edit while the record is in flight, adopts the revert when it
lands, and verifies clean. **Two things the spec did not say, both found the hard way.**
50's catch-up proof (the sender's manifest naming our version) also ends a note — but only
for a manifest *from elsewhere*: while any other delivery is in flight every open re-merges
the manifest this machine wrote, which names ours by construction, and the unguarded rule
dropped the note before the record could land (the rig); the index now remembers the digest
of the manifest it last wrote. And only a **record** triggers a reversal, hashed exactly —
a payload's landing is answerable by size alone, so its contest travels with its artifact's
record (`/code-review`). Open adopts through the poll's own reconcile, after 65's recovery,
and a failed adoption backs off. 997 engine tests on macOS (994 Linux), 162 CLI, 82 app.
