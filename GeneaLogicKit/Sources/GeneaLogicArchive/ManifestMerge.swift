import Foundation
import GeneaLogicModel

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// **Reconciling two machines' `manifest.json` after a sync provider had to pick
/// one of them** (slice 50).
///
/// Every mutation on every machine rewrites that one document, so two machines
/// editing *different* records — no record conflict anywhere, both sidecars
/// delivered intact — still produce two manifests, and a provider always picks a
/// winner. The loser's bookkeeping goes with it, and the consequence is not a
/// stale report but a **wedged archive**: the surviving manifest names the
/// pre-edit hash for a record only the other machine edited, that entry moved
/// since the last settling, so slice 60c reads it as a delivery — of a version
/// that exists nowhere and will never arrive. `manifestDeliveryLooksComplete` is
/// then false for ever, the witness never settles, the index is never reconciled,
/// 61's bar never comes down, and every further edit to that record is refused
/// with advice that forbids `rebaseline`, the one operation that would clear it.
///
/// **Why this is mergeable at all.** `manifest.files` is a *set of independent
/// per-path facts*, not a narrative: each entry is a self-contained claim about
/// one file, minted by whichever machine wrote that file. Two divergent manifests
/// can therefore be reconciled entry by entry, and the reconciliation is a
/// *choice between two claims that already exist* — never a new one.
///
/// **That is what lets this run without a human.** Slice 49 fork (a) established
/// the rule that keeps rot from being laundered: never re-hash a present entry,
/// because re-minting a rotted file's entry rewrites the evidence away. It is why
/// `rebaseline()` — which does re-mint — must be asked for explicitly. This merge
/// **mints nothing**. Every entry it emits was authored at write time by one
/// machine or the other, so 49's rule holds by construction rather than by care,
/// and the merge is safe on the automatic reconcile path.
///
/// **The rule, per path.** For each path the arriving manifest names: keep
/// **ours** when its entry is *one of the versions our own local writes replaced*
/// and the disk still holds our version; otherwise keep **theirs**.
///
/// **And since slice 50b, drop it outright when what we replaced that version
/// with was a deletion — which this machine recorded when it deleted.** The wedge has one more shape, one case over from the
/// measured one: delete a record here while the other machine writes anything at
/// all, and the manifest the provider keeps still names the record you deleted.
/// That entry is in neither the settled entries nor on disk, so 60c reads it as a
/// delivery of a version that will never arrive — and every later mutation
/// carries it forward (`Archive.awaitedPaths`), so the manifest permanently
/// describes a file that cannot exist and the deletion is undone in the
/// bookkeeping. The evidence that decides it is the one this slice already keeps:
/// `recordWhatThisMutationSuperseded` notes the entry a *deletion* replaced
/// exactly as it notes an *edit*'s. What the rule above cannot do with it is the
/// other half of the sentence — it only ever **substitutes** one entry for
/// another, and a deletion needs one **dropped**.
///
/// **What may not stand in for the deletion is an absence** (`/code-review`).
/// The rule first asked whether our *settled* entries name the path, on the
/// reading that only a manifest we committed after deleting produces one that
/// does not. They lag: `settled_file` moves when a mutation starts current or a
/// delivery settles, so while one is stuck in flight a record created and then
/// edited in that window is in `superseded_file` and has never been in
/// `settled_file` — and if its file were then lost out of band, an older
/// manifest naming the superseded version would drop the entry and the loss
/// would go unreported. `ArchiveIndex.deletedPaths()` is the positive fact
/// instead: nothing but a removal writes it, and a path authored again clears
/// it.
///
/// **The middle clause is the whole design, and the first version of this slice
/// did not have it.** Without it the rule was "the disk agrees with our settled
/// entry, so their manifest predates our write" — which is equally true of a
/// delivery still in flight, where the disk holds the old version because the new
/// one has not landed. Six of the engine's existing delivery tests said so
/// immediately. What separates the two is not on either manifest: it is the fact
/// that *we* wrote, and what we wrote over. `ArchiveIndex.supersededFiles()` is
/// that fact — **every** version each path has moved on from, not merely the one
/// it started at — and an arriving entry among them is proof the sender has not
/// heard about our write, which no amount of comparing the two manifests to each
/// other can establish.
///
/// **Deliberately narrow.** A path the arriving manifest does **not** name — our
/// own record, created after the manifest that just arrived — keeps today's
/// behaviour: the entry falls out and the next mutation mints it from disk, per
/// slice 49 fork (f)'s rule that an absent entry means *unverified*, never
/// *tampered*. Restoring those from the settled entries was tried and reverted:
/// nothing distinguishes them from a manifest legitimately rolled back by hand,
/// which is the case 49's compatibility test pins. The merge only ever corrects
/// a claim it holds positive evidence against.
///
/// **Slice 50b re-opened that and left it closed** (fork d): the residue is a
/// *window*, not a loss — the entry is covered again after the next write — and
/// restoring it would need a new *authored since the last settling* evidence
/// table that still could not tell our new record from a record **the other
/// machine deleted** whose file-deletion has not landed yet. Restoring on that
/// reading re-wedges on a file that will never arrive, which is the failure 50b
/// exists to remove. Considered and declined, not deferred.
enum ManifestMerge {
    /// The `schemaVersion` a merged manifest carries: the newer of the two, so a
    /// straggler's manifest never puts an upgraded archive back on paper (slice
    /// 64, fork g). `merge` itself is about `files` and never touches this;
    /// the caller applies it whenever it writes.
    static func schemaVersion(delivered: String, ours: String) -> String {
        SchemaVersion.newer(ours, delivered)
    }

    /// The reconciled entries, or `nil` when the arriving manifest already **is**
    /// the merge and must not be rewritten.
    ///
    /// **Returning `nil` rather than an equal array is the whole of fork (d)'s
    /// convergence.** Two machines that have exchanged manifests both compute the
    /// same set, so the second one writes nothing, its witness matches, and the
    /// exchange terminates instead of ping-ponging a rewrite each way. It is also
    /// what keeps a poll from generating sync traffic on an archive that is
    /// merely being read.
    ///
    /// Sorted by path, which is what `recomputeManifestFiles` already emits, so
    /// a merged manifest is in the same order as an engine-written one and the
    /// witness digest — which is order-sensitive by design — does not move for
    /// ordering alone.
    static func merge(
        delivered: [ManifestEntry], settled: [String: ManifestEntry],
        superseded: [String: [ManifestEntry]], deleted: Set<String>, root: URL
    ) -> [ManifestEntry]? {
        // No evidence of a local write the sender has not heard about: an index
        // written before this slice, one whose database was recreated (the
        // missing/unopenable/schema-stale branch — an ordinary
        // `rebuild(walking:)` deliberately keeps this evidence), or the ordinary
        // case of a machine that has changed nothing. The arriving manifest
        // stands, exactly as it did before this slice.
        guard !superseded.isEmpty, !settled.isEmpty else { return nil }

        // `nil` marks a dropped entry, kept positionally so the coupling pass
        // below can un-drop one without re-deciding it.
        var resolved: [ManifestEntry?] = []
        resolved.reserveCapacity(delivered.count)
        for entry in delivered {
            // Everything below turns on the sender describing a version we have
            // moved on from. Without that there is nothing to prefer ours over
            // theirs, and an entry we never superseded is a real delivery.
            guard superseded[entry.path]?.contains(entry) == true else {
                resolved.append(entry)
                continue
            }
            if deleted.contains(entry.path), nothingIsThere(at: entry.path, root: root) {
                // **Our own deletion** (slice 50b): we superseded that version,
                // this machine recorded removing the path, and nothing is there.
                //
                // **Asked before the substitution below, not after.** `settled`
                // may still name a path we deleted — it does not move while a
                // delivery is stuck in flight — and the substitution would then
                // find no file to vouch for, keep theirs, and leave the wedge
                // exactly where it was.
                //
                // **A delete loses to an edit, and that falls out rather than
                // being built:** if the other machine edited the record instead
                // of merely holding it, its manifest names a version we never
                // superseded, the guard above keeps theirs, and the record comes
                // back when it lands. The deleted sidecar is in `.trash/` on
                // either reading, so nothing is destroyed by taking the safe
                // direction.
                resolved.append(nil)
            } else if let ours = settled[entry.path], ours != entry,
                diskHolds(ours, root: root)
            {
                // **Our own later write** (slice 50): their manifest predates it,
                // and the disk still holds what we wrote.
                resolved.append(ours)
            } else {
                resolved.append(entry)
            }
        }

        // **An artifact's payload is not decided apart from its record**
        // (hand-test, 50b). The rule above is per path, which is the premise that
        // makes a manifest mergeable at all — but the two halves of one artifact
        // are not independent facts. Delete an artifact here while the other
        // machine edits it, and *a delete loses to an edit* brings the record
        // back while the payload entry is still dropped as our deletion: the
        // record then lists a preservation master that is on no disk, in no
        // manifest, and reported by nothing, with its only copy in `.trash/`,
        // which emptying deletes for good. Before this slice the same race wedged
        // the archive and reported the file as outstanding — noisy, and honest,
        // which is the direction to fail in.
        //
        // So a dropped path under an artifact folder whose `record.json`
        // **survived** the merge is un-dropped. The entry stands, the file is
        // reported missing, and the trash copy is still there to restore from.
        let survivingRecords = Set(
            zip(delivered, resolved).compactMap { entry, kept -> String? in
                kept != nil && entry.path == artifactRecordPath(for: entry.path)
                    ? entry.path : nil
            })
        for index in delivered.indices where resolved[index] == nil {
            let path = delivered[index].path
            guard let record = artifactRecordPath(for: path), record != path,
                // **The record has to have been deleted too** (`/code-review`).
                // "Its record survived" is also true of a record that was never
                // deleted — a `detachFile` on a *living* artifact notes only the
                // payload, so without this the coupling puts back the entry for
                // a file that is in `.trash/`, listed by no record, and never
                // arriving: 50b's own wedge, one case over. Only an artifact
                // whose deletion was *partly* undone qualifies.
                deleted.contains(record),
                survivingRecords.contains(record)
            else { continue }
            resolved[index] = delivered[index]
        }

        // Recomputed after the coupling, which can put back the only change there
        // was — and an unchanged merge must still write nothing (fork d).
        let changed = zip(delivered, resolved).contains { entry, kept in kept != entry }

        guard changed else { return nil }
        return resolved.compactMap { $0 }.sorted { $0.path < $1.path }
    }

    /// `artifacts/<slug>/record.json` for any path inside an artifact folder —
    /// the path itself when it *is* the record — and `nil` for anything else
    /// (`conclusions/**`, the schema spec), which has no such grouping.
    private static func artifactRecordPath(for path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ArchiveLayout.artifactsDirectoryName else {
            return nil
        }
        return "\(parts[0])/\(parts[1])/\(ArchiveLayout.recordFileName)"
    }

    /// Whether the file on disk is still the one `ours` describes — the check
    /// that keeps the merge from asserting a version the archive no longer holds.
    ///
    /// **Size first, and for a payload file size only.** A `stat(2)` is
    /// dataless-correct — a cloud placeholder reports its true length in
    /// `st_size` (slice 57's measurement) — so it answers without touching a
    /// byte, and it must stay that way for payload: hashing a placeholder
    /// *materializes* it, turning a reconcile into a download. An engine-authored
    /// file is small and local by definition (we wrote it), so it gets the exact
    /// answer, and the hash can only ever **confirm** an entry that already
    /// exists — nothing here mints one.
    ///
    /// **An absent file is not ours**, because absent is also what an arrival
    /// looks like before it lands.
    static func diskHolds(_ ours: ManifestEntry, root: URL) -> Bool {
        let url = root.appendingPathComponent(ours.path)
        guard let size = fileSize(of: url) else { return false }
        guard size == ours.byteLength else { return false }
        guard ArchiveLayout.isEngineAuthored(relativePath: ours.path) else { return true }
        // Same length is not the same bytes. For a file we author — small, and
        // local by definition, since we wrote it — one hash settles it, and the
        // answer can only ever *confirm* a hash that already exists: nothing here
        // mints one.
        return (try? Checksum.sha256Hex(ofFileAt: url)) == ours.sha256
    }

    /// Whether **nothing at all** is at `path` — the deletion branch's third
    /// fact, and deliberately narrower than `fileSize(of:)` returning `nil`.
    ///
    /// A directory sitting where a record belongs is not an absence: it is
    /// something to report, and dropping the entry would take away the only
    /// document that says the file is expected.
    ///
    /// **`lstat`, and only `ENOENT`** (`/code-review`, 50b). "The `stat` failed"
    /// is not the same claim: `EACCES` on a parent directory, or an `EIO`, is the
    /// archive telling us it cannot answer, and reading that as *deleted* would
    /// license the drop on exactly the machine that can see least. `lstat` rather
    /// than `stat` for the same reason one step out — a **dangling symlink** where
    /// a record belongs fails `stat` with `ENOENT` while something is plainly
    /// there to report. Only *there is no such path* reads as *deleted*.
    static func nothingIsThere(at path: String, root: URL) -> Bool {
        (try? AtomicIO.isAbsent(root.appendingPathComponent(path))) ?? false
    }

    /// `st_size`, or `nil` when there is no regular file there. Never a read.
    private static func fileSize(of url: URL) -> Int64? {
        guard let st = statOf(url), st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(st.st_size)
    }

    /// `stat(2)`, or `nil` when the path cannot be stat'ed at all.
    private static func statOf(_ url: URL) -> stat? {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &st) == 0 } ?? false
        }
        return ok ? st : nil
    }
}
