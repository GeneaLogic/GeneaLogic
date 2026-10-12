import Foundation
import GeneaLogicModel

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Integrity verification (ARCHITECTURE.md §3, §6.3): "is this archive exactly
/// what `manifest.json` says it is, and is there anything extra lying around?"
extension Archive {

    /// What the archive already knows is wrong, without reading any file's
    /// contents (slice 56).
    ///
    /// `verifyIntegrity()` answers the same question far more thoroughly and
    /// SHA-256s every tracked file to do it — a cost a host cannot pay on every
    /// open, which meant the cheapest finding in the engine was reachable only
    /// through its most expensive call. Everything here is already recorded in
    /// `.index/`: a `SELECT` over two tiny tables, a flag read, and an `lstat` per
    /// preserved copy (58d) — a table that is normally empty.
    ///
    /// **Deliberately a struct rather than `[IntegrityReport.Issue]`.** Without
    /// hashing, "a write died" can only be said as a flag: `.interruptedWrite`
    /// names a *file*, and naming one requires exactly the comparison this call
    /// refuses to make. A type that cannot express a claim it cannot support is
    /// the point — a host that wants per-path answers has to go and pay for them.
    public struct StandingFindings: Sendable, Equatable {
        /// The records the last rebuild skipped, sorted by path, each with why
        /// (slice 64). They are on disk and absent from every query — see
        /// `IntegrityReport.Issue.unreadableRecord`. A host that shows them
        /// must word them by reason: an `.olderFormat` record is intact, and
        /// "couldn't be read" about it is the wrong sentence (`/code-review`).
        public var unreadable: [UnreadableRecord]

        /// The paths alone, both reasons — the list a host feeds to
        /// `repairPlans(forRecordsAt:)` and keys its placeholder rows on.
        public var unreadableRecords: [String] { unreadable.map(\.path) }

        /// The paths of the skipped records that are **damage** — couldn't be
        /// decoded — leaving out the intact older-format ones (slice 71). What a
        /// host asks when it is about to say something is wrong: before slice 71 the
        /// banner was asking `unreadableRecords` instead.
        public var undecodableRecords: [String] {
            unreadable.filter { $0.reason == .undecodable }.map(\.path)
        }

        /// Records whose file is **gone** but whose last bytes the index still
        /// holds, sorted (slice 58d) — the `missingFile` findings that can be
        /// restored, or discarded to accept the loss.
        ///
        /// A path is here when it has a preserved copy, the manifest still names
        /// it, nothing is on disk there, and no delivery in flight explains the
        /// absence. That is exactly the set `verifyIntegrity()` reports
        /// `missingFile` *and* `repairPlans(forRecordsAt:)` answers. Disjoint from
        /// `unreadable` by construction: a file that is there either reads (and
        /// its copy was pruned) or is unreadable.
        ///
        /// **Only copies, deliberately.** A sidecar that vanished with no copy has
        /// nothing to offer and keeps its entry only until the next write (58c's
        /// residue); one that vanished with no rebuild since is still a live row,
        /// shown normally. Neither looks absent in a way a host can answer.
        public var vanished: [String]

        /// Whether a mutation is known to have died before the manifest caught
        /// up, so *some* engine-authored file may not match its recorded hash.
        /// Which one, this call cannot say.
        public var interruptedWriteSuspected: Bool

        public var isEmpty: Bool {
            unreadable.isEmpty && vanished.isEmpty && !interruptedWriteSuspected
        }

        public init(
            unreadable: [UnreadableRecord] = [], vanished: [String] = [],
            interruptedWriteSuspected: Bool = false
        ) {
            self.unreadable = unreadable
            self.vanished = vanished
            self.interruptedWriteSuspected = interruptedWriteSuspected
        }
    }

    /// The findings that cost nothing to read — see `StandingFindings`. Safe to
    /// call on every open, and on every external-change refresh.
    ///
    /// **Throws rather than reporting an unreadable index as a clean archive**
    /// (review finding, 56). A failed read here means the index connection is in
    /// trouble, which is the opposite of good news; swallowing it would let the
    /// one call a host makes on every refresh answer "nothing wrong" for a reason
    /// that is itself something wrong. The caller decides what to do with that —
    /// and per the type's own rule, a value that cannot say "I couldn't check"
    /// must not be returned when that is what happened.
    public func standingFindings() throws -> StandingFindings {
        let (skipped, vanished) = try withReadState { manifest, index in
            (
                try index.unreadableRecords(),
                try restorableVanishedPaths(manifest: manifest, index: index)
            )
        }
        return StandingFindings(
            unreadable: skipped.map { UnreadableRecord(path: $0.path, reason: $0.reason) },
            vanished: vanished,
            interruptedWriteSuspected: interruptedWriteSuspected)
    }

    /// `StandingFindings.vanished`, for a caller holding the lock.
    ///
    /// Classified as `verifyIntegrity()` classifies an absent entry, minus the
    /// interrupted-write branch — which can never claim a path with a copy:
    /// `interruptedWriteEvidence` counts every copy as *referenced* (58c), so a
    /// known loss is never read as a died write's residue. A copy the file system
    /// cannot answer for (`isGone` is `nil`) is left out: this call speaks only
    /// for what it can see, and the next refresh asks again.
    ///
    /// Not `vanishedRecordPaths(index:named:unreadable:)`, the manifest carry's
    /// set (`/code-review`): that one deliberately neither probes the disk nor
    /// asks about deliveries, because it must keep an entry this one would not
    /// report.
    func restorableVanishedPaths(manifest: Manifest, index: ArchiveIndex) throws -> [String] {
        let copies = try index.preservedRecordPaths()
        guard !copies.isEmpty else { return [] }
        let entries = Dictionary(
            manifest.files.lazy.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let delivery = deliveryCoverageLocked()
        return copies.filter { path in
            guard let entry = entries[path], !delivery.covers(entry) else { return false }
            return ArchiveIndex.isGone(rootURL.appendingPathComponent(path)) == true
        }
    }

    // MARK: - The cheap sweep (slice 57)

    /// The result of `sweepFileSizes()` — Tier 2 of the three tiers 56 separated
    /// out (free / cheap / hashing).
    ///
    /// **Deliberately not an `IntegrityReport`,** even though it reports through
    /// that type's `Issue` kinds. `IntegrityReport.isClean` means *verified*, and
    /// this sweep never verifies anything: it cannot see damage that keeps a
    /// file's length, which is most bit rot. A host holding a value with an
    /// `isClean` on it will eventually render "Archive Is Intact" from it — the
    /// string already exists — so the property here is `foundNothingMissing`,
    /// which that sentence cannot be written from. Same rule as
    /// `StandingFindings`: a type that cannot express a claim it cannot support.
    public struct FileSweepReport: Sendable, Equatable {
        /// Since slice 60 also `.awaitingDelivery`, which is neither a fault nor
        /// something a host should count: it means the manifest is ahead of the
        /// disk because a change is still arriving from another machine. Hosts
        /// must not fold it into a damage headline — see `FileDamageSummary`.
        ///
        /// Only ever `.missingFile` and `.sizeMismatch` — the two `verifyIntegrity()`
        /// kinds reachable without reading a byte, so no host's switch changes.
        ///
        /// **These are certain, and so are stated without hedging.** The weak half
        /// of this sweep is its silence, not its findings: the manifest says 700319
        /// bytes and `stat` says 4096 is a fact, not an inference.
        public var issues: [IntegrityReport.Issue]

        /// How many manifest entries were actually `stat`ed — so "found nothing"
        /// can be told apart from "had nothing to check", the same ambiguity
        /// `IntegrityReport.trackedFileCount` exists for.
        public var checkedFileCount: Int

        /// How many of those are cloud placeholders — present, tracked, correct,
        /// but with no bytes on this machine (`SF_DATALESS`; always 0 off Darwin).
        ///
        /// Counted rather than acted on. Measurement (slice 57, fork c) settled
        /// that a dataless file `stat`s to its **true** length, so it sweeps
        /// correctly and needs no special case. What it does change is what a
        /// silent sweep is worth — its size came from the file provider's
        /// metadata, not from local bytes — and this is the number a host would
        /// need to say so.
        public var datalessFileCount: Int

        /// `true` when nothing is absent and nothing is the wrong length. **Not
        /// `isClean`** — see the type's note.
        public var foundNothingMissing: Bool { issues.isEmpty }

        public init(
            issues: [IntegrityReport.Issue] = [],
            checkedFileCount: Int = 0,
            datalessFileCount: Int = 0
        ) {
            self.issues = issues
            self.checkedFileCount = checkedFileCount
            self.datalessFileCount = datalessFileCount
        }
    }

    /// Whether every `manifest.files` entry **this delivery is bringing** is
    /// present at its recorded size — the same `st_size` comparison
    /// `sweepFileSizes()` makes, reduced to one bool and usable before an
    /// `Archive` exists (slice 60, fork e; narrowed from *every* entry to the
    /// delivery's own by 60c's hand-test — see the note at the loop).
    ///
    /// **What it is for: sync is not atomic across files.** A machine can receive
    /// the new `manifest.json` *before* the new `record.json` it describes.
    /// Rebuilding then and recording the resulting witness would be the worst
    /// available outcome — the manifest does not change again when the sidecar
    /// finally lands, so **nothing would re-trigger** and the index would stay
    /// stale permanently, which is worse than the bug slice 60 fixes. So a
    /// witness-driven rebuild advances the witness only if this says the delivery
    /// looks whole, and otherwise **leaves the previously settled witness in
    /// place** — which still disagrees with the disk, so the next check runs
    /// again, and which is also what keeps *arriving* distinguishable from
    /// *damaged*. See `Archive.recordWitness`.
    ///
    /// **Never hash here.** Hashing a dataless file *materializes* it (slice 57's
    /// out-of-scope finding), so a completeness check that hashed would turn every
    /// poll on a synced archive into a whole-archive download. Comparing `st_size`
    /// is dataless-correct: a cloud placeholder reports its true length there.
    ///
    /// The accepted limit is the same one `sweepFileSizes()` documents: a partial
    /// delivery that happens to preserve every file's size is invisible. The cost
    /// of that miss is one stale index until the next manifest change, not
    /// corruption.
    static func manifestDeliveryLooksComplete(
        root: URL, manifest: Manifest, settled: [String: ManifestEntry]
    ) -> Bool {
        for entry in manifest.files {
            // **An entry that has not moved since the last settling is not part
            // of this delivery, so its bytes cannot say whether the delivery
            // finished** (slice 60c, hand-test). This gate was archive-wide like
            // everything else the flag drove, and the consequence was worse than
            // a mislabelled report: an archive that was *damaged* when a delivery
            // landed could never settle again, because the damaged file is the
            // wrong size for ever. So `deliveryIsInFlight` stayed true with
            // nothing arriving — 61's bar up permanently, every open re-walking
            // the archive, `awaitedPaths` carrying entries — and no surface could
            // explain it, since the delivery had in fact completed.
            //
            // The protection this check exists for is untouched: a `record.json`
            // that has not arrived yet is named by a manifest entry that **did**
            // move, so it is still checked, and the witness still waits for it.
            // Skipping is only ever the entries the delivery is not bringing.
            //
            // An empty `settled` skips nothing, which is the pre-60c behaviour
            // and the right answer for an index that cannot tell the two apart —
            // including 60b's fresh, witnessless one.
            if settled[entry.path] == entry { continue }
            let fileURL = root.appendingPathComponent(entry.path)
            var st = stat()
            let ok = fileURL.withUnsafeFileSystemRepresentation { path in
                path.map { stat($0, &st) == 0 } ?? false
            }
            guard ok, st.st_mode & S_IFMT == S_IFREG, Int64(st.st_size) == entry.byteLength
            else { return false }
        }
        return true
    }

    /// Existence and size for every `manifest.files` entry — one `stat(2)` each,
    /// no reads, no hashing (slice 57). Milliseconds for a few hundred files,
    /// so it is safe where `standingFindings()` is safe: every open, every
    /// external-change refresh.
    ///
    /// It answers a question `standingFindings()` cannot. 56 surfaces what the
    /// archive already *knows*; a file deleted or truncated on disk commits
    /// nothing to the index, so nothing knows it until someone pays for
    /// `verifyIntegrity()`. This is the cheap path to that same answer, minus the
    /// hashing — which also means it is **not** verification, and must never be
    /// presented as any (see `FileSweepReport`).
    ///
    /// **Compare `st_size` and nothing else.** A cloud placeholder reports its
    /// true length in `st_size` while `st_blocks`, `fileAllocatedSize`, and
    /// `totalFileAllocatedSize` all read **0** (measured, slice 57 fork c) — so
    /// "optimizing" this to an allocated size would report every un-downloaded
    /// preservation master as truncated, on exactly the archives that most need
    /// the sweep. `UF_COMPRESSED` is a second reason: block counts under-report
    /// for locally compressed files too.
    ///
    /// Deliberately **not** mtime, which the manifest doesn't record and which is
    /// not preserved across copies, restores, or sync providers — adding it would
    /// be both a format change and a false-positive engine (fork a).
    public func sweepFileSizes() -> FileSweepReport {
        let manifestSnapshot = withReadState { manifest, _ in manifest }
        let interruptedWrite = interruptedWriteSuspected
        let evidence =
            interruptedWrite ? try? withIndex { try interruptedWriteEvidence(index: $0) } : nil
        // **Per entry, not archive-wide** (slice 60c): a file that was already
        // damaged when the delivery started is not one of the files it is
        // bringing, and saying otherwise silenced this sweep's banner for the
        // whole download. See `DeliveryCoverage`.
        let delivery = deliveryCoverage()

        var issues: [IntegrityReport.Issue] = []
        var dataless = 0

        for entry in manifestSnapshot.files {
            let fileURL = rootURL.appendingPathComponent(entry.path)

            var st = stat()
            guard
                fileURL.withUnsafeFileSystemRepresentation({ path in
                    path.map { stat($0, &st) == 0 } ?? false
                })
            else {
                // Classified as `verifyIntegrity()` classifies it (slice 65).
                if delivery.covers(entry) {
                    issues.append(.awaitingDelivery(path: entry.path))
                } else if evidence?.explains(entry, actualSHA256: nil) == true {
                    issues.append(.interruptedWrite(path: entry.path))
                } else {
                    issues.append(.missingFile(path: entry.path))
                }
                continue
            }

            // A directory (or anything else) where a tracked file belongs is
            // absent in the sense that matters, and is what `verifyIntegrity()`
            // reports for the same shape.
            guard st.st_mode & S_IFMT == S_IFREG else {
                issues.append(
                    delivery.covers(entry)
                        ? .awaitingDelivery(path: entry.path) : .missingFile(path: entry.path))
                continue
            }

            if Archive.isDataless(st) { dataless += 1 }

            let size = Int64(st.st_size)
            if size != entry.byteLength {
                // **Classified exactly as `verifyIntegrity()` classifies it**, and
                // that agreement is the point: a mutation that died between its
                // sidecar write and its manifest write leaves this shape, and
                // calling it a size mismatch is an accusation the archive's own
                // history contradicts. Both calls have everything they need to
                // say so — the sentinel, the path, and whether the engine wrote
                // it — so a banner and the panel behind it must not describe one
                // on-disk state two different ways (review finding, 57).
                // A payload's sidecar that already records this size is the
                // size-only half of verify's rule (slice 65, fork c).
                if interruptedWrite,
                    ArchiveLayout.isEngineAuthored(relativePath: entry.path)
                        || evidence?.sidecarEntries[entry.path].map({
                            $0 != entry && $0.byteLength == size
                        }) == true
                {
                    issues.append(.interruptedWrite(path: entry.path))
                } else if delivery.covers(entry) {
                    issues.append(.awaitingDelivery(path: entry.path))
                } else {
                    issues.append(
                        .sizeMismatch(path: entry.path, expected: entry.byteLength, actual: size))
                }
            }
        }

        // **Did the ground move while we walked?** The sweep takes no lock
        // (neither does `verifyIntegrity()` — see `withReadState`), so a
        // concurrent writer that removes files before committing its manifest is
        // seen mid-mutation, and every file it is moving reads as missing. That
        // would put "N files are missing" in the one banner meant never to cry
        // wolf, for a fault that isn't one. If the manifest moved under us, the
        // walk described an archive that no longer exists: report nothing and let
        // the next poll say what is actually true (review finding, 57).
        //
        // **This narrows the window; it does not close it.** A writer that
        // commits *after* this second read still leaves one poll's worth of false
        // missing files, and closing that properly means holding the archive lock
        // across the whole walk — which is exactly what this call is designed not
        // to do. `withReadState` re-reads the manifest from disk on every call
        // (see its note), so this does see another process's commit, which is the
        // case worth catching.
        let manifestNow = withReadState { manifest, _ in manifest }
        guard manifestNow == manifestSnapshot else {
            return FileSweepReport(checkedFileCount: 0, datalessFileCount: 0)
        }

        return FileSweepReport(
            issues: issues,
            checkedFileCount: manifestSnapshot.files.count,
            datalessFileCount: dataless)
    }

    // MARK: - Are this file's bytes on this machine?

    /// Whether a `stat(2)` describes a **cloud placeholder** — a file that is
    /// present, tracked and correctly sized, but whose bytes are not on this
    /// machine and would have to be downloaded to read (measured, slice 57 fork
    /// c: `SF_DATALESS`, alongside `UF_COMPRESSED|UF_TRACKED`, with `st_size`
    /// carrying the file's **true** length and `st_blocks` reading 0).
    ///
    /// **Always `false` off Darwin**, where no such thing exists — which is what
    /// makes every caller's behaviour byte-identical on Linux without a single
    /// `#if` in the logic above (slice 57b, fork c).
    ///
    /// **What it is not.** `SF_DATALESS` is what iCloud Drive sets; whether
    /// Dropbox or OneDrive placeholders set it on current macOS is unmeasured,
    /// and nothing here should be read as claiming they do. An unrecognised
    /// placeholder simply reads as materialized and is hashed, which is the
    /// pre-57b behaviour exactly — the degradation is in the safe direction.
    ///
    /// **And it is a per-*file* state, which a package's interior never has**
    /// (measured, 57b's hand-test, on a package-born `.genea` in iCloud Drive).
    /// Files in an ordinary synced directory each carry their own ubiquity
    /// identity and go dataless individually; the interior of a `.genea` carries
    /// none — `downloading`/`uploaded`/`uploading` all read `nil` — because the
    /// **package** is the ubiquitous item. Eviction happens to the package, any
    /// access to a path inside materializes the whole of it, and its files read
    /// fully present the instant you can see them at all. So on iCloud this
    /// returns `false` for every file in a `.genea`, and the skip above never
    /// fires there. See slice 57b's spec for what that leaves standing.
    static func isDataless(_ st: stat) -> Bool {
        #if canImport(Darwin)
        return st.st_flags & UInt32(bitPattern: SF_DATALESS) != 0
        #else
        return false
        #endif
    }

    /// The same question for a URL — one `stat(2)`, which does **not** materialize
    /// the file (measured, slice 57: neither `stat` nor `URL.resourceValues` pulls
    /// the bytes down).
    ///
    /// A file that cannot be `stat`ed is not a placeholder; `verifyIntegrity()`
    /// has already established the file exists by the time it asks.
    static func fileIsDataless(at url: URL) -> Bool {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &st) == 0 } ?? false
        }
        return ok && isDataless(st)
    }

    // MARK: - The hash pass

    /// Walks every entry in `manifest.json` and the archive's on-disk contents,
    /// reporting every discrepancy found. Never throws for *content* problems —
    /// those are the whole point of the report — with one exception: **a record
    /// from a newer GeneaLogic is refused, not reported** (slice 70, fork b).
    /// Every record that differs from its entry has its stamp read before it is
    /// called a mismatch, and a newer one throws `archiveNewerThanBuild`, as
    /// `open` and `rebaseline()` do; so does one with no entry, through the
    /// same scan `open` runs. Calling an intact record from a newer build
    /// corruption, and offering *Accept Current Contents* for it, was the
    /// defect: this build's verdicts about that archive are not its to give.
    ///
    /// Checks performed, per `manifest.files` entry:
    ///   - **presence** — does a file exist at `path`? (`.missingFile` if not;
    ///     skips the size/checksum checks for that entry, since there's nothing
    ///     to measure)
    ///   - **size** — does the on-disk byte count match `byteLength`?
    ///     (`.sizeMismatch`; checked independently of the checksum so a
    ///     short-read is diagnosable even if hashing the truncated file happens
    ///     to still mismatch)
    ///   - **checksum** — does the on-disk SHA-256 match `sha256`?
    ///     (`.checksumMismatch`)
    ///
    /// Plus an archive-wide **unreferenced-file** sweep (see
    /// `findUnreferencedFiles` for the exemption set — getting this list right is
    /// the difference between a useful report and a wall of false positives).
    ///
    /// **Files whose bytes are not on this machine are not read** (slice 57b).
    /// Hashing a cloud placeholder *materializes* it, so on a synced archive with
    /// un-downloaded preservation masters this call was not merely slow — it was a
    /// whole-archive download, started by a menu item that did not say so and
    /// ending in a report that claimed the archive was intact. **Where that
    /// arises is narrower than the slice assumed**: an archive kept as an ordinary
    /// directory, or a provider that places per-file placeholders. A `.genea` on
    /// iCloud has no dataless interior at all — see `Archive.isDataless`. Such an entry is
    /// still checked for presence and size (`st_size` is a placeholder's true
    /// length) and is then named in `report.notChecked`, which drives
    /// `isComplete`. Pass `includingDatalessFiles: true` to hash them anyway —
    /// **that downloads every one of them**, and is the pre-57b behaviour.
    ///
    /// The skip covers this pass's payload hashing, which is where the gigabytes
    /// are. The record walk below still reads sidecars, as `rebaseline()` does:
    /// they are kilobytes, and a report that could not read the records could not
    /// say anything about them.
    ///
    /// **`notChecked` is every file that went unread, not only the skipped ones.**
    /// A read that fails lands there too — it used to be swallowed by a `try?`,
    /// which left a clean *and* complete report over a file nobody had read.
    ///
    /// **Cancellable.** `Task.isCancelled` is consulted between entries and
    /// between 1 MiB chunks (so an opted-in download can actually be stopped
    /// mid-file), and every entry the pass never reached comes back as unread.
    /// A stopped check therefore cannot be told apart from a finished one by
    /// accident: `isComplete` is false and says which files it means.
    ///
    /// - Parameter includingDatalessFiles: Hash files that are not downloaded to
    ///   this machine, downloading each one to do it. Defaults to `false`: a
    ///   verification reports what it did not check rather than paying an
    ///   unasked-for bill to check it.
    /// - Returns: An `IntegrityReport` whose `issues` is empty (`isClean == true`)
    ///   when nothing is wrong, and whose `notChecked` is empty (`isComplete ==
    ///   true`) when everything was actually read.
    public func verifyIntegrity(includingDatalessFiles: Bool = false) throws -> IntegrityReport {
        try verifyIntegrity(
            includingDatalessFiles: includingDatalessFiles, isDataless: Archive.fileIsDataless(at:))
    }

    /// The pass, with the placeholder test injected.
    ///
    /// **The one seam, and why it exists** (slice 57b, fork e): nothing in CI can
    /// produce an `SF_DATALESS` file — 57 measured the flag on a real iCloud
    /// placeholder by hand and could hold no more than "nothing local is
    /// dataless". Skipped, checked, opted-in and Linux-no-op would all have been
    /// claims rather than tests. The *signal* stays exactly what 57 measured
    /// (`Archive.fileIsDataless(at:)`, the default); only the question is
    /// substitutable.
    func verifyIntegrity(
        includingDatalessFiles: Bool, isDataless: (URL) -> Bool
    ) throws -> IntegrityReport {
        var issues: [IntegrityReport.Issue] = []
        var notChecked: [IntegrityReport.NotCheckedFile] = []
        let fm = FileManager.default

        let (manifestSnapshot, indexSnapshot) = withReadState { manifest, index in
            (manifest, index)
        }
        // A newer record with no entry is one the pass below never reaches.
        try Migration.refuseIfAnyMovedRecordIsAhead(of: manifestSnapshot, in: rootURL)
        let interruptedWrite = interruptedWriteSuspected
        // Only consulted under the flag, so only built under it.
        let evidence =
            interruptedWrite ? try? withIndex { try interruptedWriteEvidence(index: $0) } : nil
        // Per entry (slice 60c) — a rotted file reported as *still arriving*
        // because something unrelated was in flight is the report this slice
        // exists to stop.
        let delivery = deliveryCoverage()

        // The index of the first entry a cancelled pass never reached, if it was
        // cancelled. See the tail below for what is done with it.
        var stoppedFrom: Int?

        for (offset, entry) in manifestSnapshot.files.enumerated() {
            // **Between files as well as inside them.** The per-chunk check
            // handed to `Checksum` bounds one big read; this bounds the walk, and
            // catches a cancellation that arrives while the pass is between two
            // files it can read instantly.
            if Task.isCancelled {
                stoppedFrom = offset
                break
            }

            let fileURL = rootURL.appendingPathComponent(entry.path)

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                // A record named by a manifest that arrived ahead of it is not a
                // missing file, it is one that has not landed yet (slice 60) —
                // provided this delivery is the reason it is absent (60c). And one
                // the archive's own view has moved past, under the sentinel, is a
                // removal whose manifest never caught up (slice 65, fork c).
                if delivery.covers(entry) {
                    issues.append(.awaitingDelivery(path: entry.path))
                } else if evidence?.explains(entry, actualSHA256: nil) == true {
                    issues.append(.interruptedWrite(path: entry.path))
                } else {
                    issues.append(.missingFile(path: entry.path))
                }
                continue
            }

            var mismatches: [IntegrityReport.Issue] = []
            var actualSHA256: String?
            var sizeMoved = false
            if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                size != entry.byteLength
            {
                sizeMoved = true
                mismatches.append(
                    .sizeMismatch(path: entry.path, expected: entry.byteLength, actual: size))
            }

            // **The skip, and it is only the hash** (slice 57b). Presence and
            // size are free and dataless-correct — a placeholder `stat`s to its
            // true length — so they are made here as they always were, and a
            // placeholder whose recorded size no longer matches is still reported
            // as damage. What is not paid for is the download, and the file is
            // named in `notChecked` so the report cannot pass itself off as a
            // full verification.
            let dataless = isDataless(fileURL)
            if !includingDatalessFiles, dataless {
                notChecked.append(
                    .init(
                        path: entry.path, byteLength: entry.byteLength,
                        reason: .notOnThisMachine))
            } else {
                do {
                    let actual = try Checksum.sha256Hex(
                        ofFileAt: fileURL, isCancelled: { Task.isCancelled })
                    actualSHA256 = actual
                    if actual != entry.sha256 {
                        mismatches.append(
                            .checksumMismatch(
                                path: entry.path, expected: entry.sha256, actual: actual))
                    }
                } catch Checksum.ChecksumError.cancelled {
                    stoppedFrom = offset + 1
                    notChecked.append(
                        .init(
                            path: entry.path, byteLength: entry.byteLength,
                            reason: .checkWasStopped))
                } catch {
                    // **A read that fails must not vanish** (`/code-review`,
                    // 57b). This was `try?`, so an unreadable file — an I/O
                    // error, a permission problem, or a download that did not
                    // complete on the opt-in path — contributed nothing to the
                    // report at all, and the pass came back clean *and* complete
                    // over a file nobody had read. That is precisely the claim
                    // this slice exists to prevent, and it was reachable on the
                    // path this slice added.
                    notChecked.append(
                        .init(
                            path: entry.path, byteLength: entry.byteLength,
                            reason: .couldNotRead))
                }
            }

            // A mutation that died between its sidecar write and its manifest
            // write leaves exactly this shape, and calling it corruption would be
            // an accusation the archive's own history contradicts. One issue
            // replaces both mismatches — a truncated write is impossible here
            // (`AtomicIO` renames a complete temp file into place), so the size
            // difference is the same fact as the hash difference, said twice.
            //
            // **Order matters, and `.interruptedWrite` wins.** Both can be true
            // at once; the sentinel is the more specific fact — *this* archive's
            // own write died here — while the coverage test says only that a
            // delivery from elsewhere is bringing this path. Slice 60c narrowed
            // that second claim from *somewhere in this archive* to *this file*,
            // which brings them closer together without reversing them: an
            // interrupted write of ours is a fault we can name, and an arrival is
            // not. Neither promises the file is intact; see both doc comments.
            //
            // **A payload qualifies too when its sidecar already describes the
            // bytes** (slice 65, fork c): the record caught up and the manifest
            // did not. Rot cannot produce that shape — it changes the bytes, not
            // the record that hashed them.
            // Before any classification: a record from a newer build is none of
            // them (slice 70, fork b). **Only what the scan above did not read**
            // (`/code-review`, 70): a record whose size moved was read there,
            // unless its bytes were off this machine — so this is a same-size one
            // caught by its hash, or one this pass downloaded because it was
            // asked to. A file the pass did not hash is not read here either.
            if let actual = actualSHA256, actual != entry.sha256,
                !sizeMoved || dataless,
                ArchiveLayout.isEngineAuthored(relativePath: entry.path)
            {
                try Migration.refuseIfAhead(recordAt: fileURL, path: entry.path)
            }
            if interruptedWrite, !mismatches.isEmpty,
                ArchiveLayout.isEngineAuthored(relativePath: entry.path)
                    || evidence?.explains(entry, actualSHA256: actualSHA256) == true
            {
                issues.append(.interruptedWrite(path: entry.path))
            } else if delivery.covers(entry), !mismatches.isEmpty {
                issues.append(.awaitingDelivery(path: entry.path))
            } else {
                issues.append(contentsOf: mismatches)
            }

            // Deliberately after the classification, so the size finding this
            // entry did produce is not thrown away by the cancellation that
            // interrupted its hash.
            if stoppedFrom != nil { break }
        }

        // **A cancelled pass describes itself exactly.** Every entry it never
        // reached is reported as unread, so `isComplete` is false and no surface
        // can render a stopped check as a finished one — the same rule the skip
        // itself follows, applied to the other way a file goes unread. The walks
        // below are skipped: they answer questions this pass is no longer
        // answering, and a user who asked it to stop should not wait on them.
        if let stoppedFrom {
            for entry in manifestSnapshot.files[stoppedFrom...] {
                notChecked.append(
                    .init(
                        path: entry.path, byteLength: entry.byteLength,
                        reason: .checkWasStopped))
            }
            return IntegrityReport(
                issues: issues, trackedFileCount: manifestSnapshot.files.count,
                notChecked: notChecked)
        }

        // Files claiming to be records the archive already has, or holding one
        // under the wrong name (slice 50c). Walked fresh rather than read back
        // from something the last rebuild recorded: a conflicted copy of a
        // *conclusion* does not change `manifest.json`, so nothing triggers a
        // rebuild when one arrives, and an answer that waited for the next one
        // would report a clean archive with a shadow sitting in it. A handful of
        // `readdir`s and a parse per record, on the call that is already
        // SHA-256ing every file.
        let discovery = findRecordDiscoveryIssues(manifest: manifestSnapshot, index: indexSnapshot)

        // **Filtered, so one file is never described two ways** (`/code-review`,
        // 50c). A conflicted copy of a `record.json` lands in an artifact folder,
        // which is exactly what the stray sweep looks at — and "Stray Files" is
        // the classification that invites deleting it unread.
        let named = Set(discovery.map(\.path))
        issues.append(
            contentsOf: findUnreferencedFiles(manifest: manifestSnapshot, index: indexSnapshot)
                .filter { !named.contains($0.path) })
        issues.append(contentsOf: discovery)

        // Records the last rebuild had to skip (slice 55). Read from the index
        // rather than re-decoded here — see `.unreadableRecord`'s doc comment for
        // why that is the whole check and not half of one.
        let unreadable = (try? withReadState { _, index in try index.unreadableRecords() })
        issues.append(
            contentsOf: (unreadable ?? []).map {
                .unreadableRecord(path: $0.path, reason: $0.reason)
            }
        )

        let abandoned = withReadState { manifest, index in
            standingAbandonments(against: manifest.files, on: index)
        }

        return IntegrityReport(
            issues: issues, trackedFileCount: manifestSnapshot.files.count,
            abandonedPaths: abandoned, notChecked: notChecked)
    }

    /// Every file on disk that claims to be a record the archive already has, or
    /// that holds a record under a name the archive does not look for (slice
    /// 50c). See `IntegrityReport.Issue.conflictingCopy` and `.misnamedRecord`
    /// for what each means, and `RecordDiscovery` for the naming rule, which
    /// `ArchiveIndex.rebuild` applies to the same directories so the two cannot
    /// disagree about which file is the record.
    ///
    /// **Structural, not textual** (fork d): nothing here looks for
    /// `(conflicted copy` or a ` 2` suffix. A conclusion file is the record iff
    /// it is named for the uid inside it; a file beside a `record.json` is a copy
    /// of it iff it decodes as an `Artifact`.
    ///
    /// **Which of the two kinds a finding gets turns on whether the record is
    /// present under its own name** (`/code-review`, 50c). Without that test the
    /// sole surviving copy of a record — a provider that renamed the original
    /// rather than the copy — was reported as a duplicate, with advice to delete
    /// it.
    ///
    /// **A file that cannot be decoded is not reported here.** It is either
    /// already `.unreadableRecord` or already covered by its manifest entry, and
    /// a copy the engine cannot read is not one it can say anything about.
    ///
    /// **"Present under its own name" is decided against the directory listing,
    /// not `fileExists`** (slice 63's archive property, on macOS). A uid that
    /// differs from its file name in case alone — one flipped bit in `b65` —
    /// exists to APFS's case-insensitive lookup, so the sole surviving copy of
    /// that record was reported as a duplicate, with advice to delete it; Linux
    /// said `.misnamedRecord`. The rule `RecordDiscovery` applies is exact
    /// string equality, and this comparison has to be the same rule.
    private func findRecordDiscoveryIssues(manifest: Manifest, index: ArchiveIndex)
        -> [IntegrityReport.Issue]
    {
        var found: [(path: String, uid: String?)] = []

        func scanConclusions<Record: Decodable>(
            _ directory: String, as type: Record.Type, uid: (Record) -> String
        ) {
            let url = rootURL.appendingPathComponent(directory, isDirectory: true)
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { return }

            let names = Set(files.map(\.lastPathComponent))
            for file in files where file.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: file),
                    let record = try? GeneaLogicJSONCoding.decoder.decode(type, from: data)
                else { continue }
                let recordUID = uid(record)
                guard !RecordDiscovery.isCanonicalConclusionFile(file, uid: recordUID) else {
                    continue
                }
                found.append(
                    (
                        ArchiveLayout.relativePath(of: file, in: rootURL),
                        names.contains("\(recordUID).json") ? nil : recordUID
                    ))
            }
        }

        scanConclusions(
            ArchiveLayout.personsDirectoryRelativePath, as: Person.self, uid: { $0.uid.raw })
        scanConclusions(
            ArchiveLayout.relationshipsDirectoryRelativePath, as: Relationship.self,
            uid: { $0.uid.raw })
        scanConclusions(
            ArchiveLayout.linksDirectoryRelativePath, as: EvidenceLink.self, uid: { $0.uid.raw })
        scanConclusions(
            ArchiveLayout.dismissalsDirectoryRelativePath, as: Dismissal.self, uid: { $0.uid.raw })

        found.append(contentsOf: scanArtifactFolders(manifest: manifest, index: index))

        return found.sorted { $0.path < $1.path }.map { finding in
            if let uid = finding.uid {
                return .misnamedRecord(path: finding.path, uid: uid)
            }
            return .conflictingCopy(path: finding.path)
        }
    }

    /// The artifact half: a duplicated `artifacts/<slug>/` folder, and a copy of
    /// a `record.json` sitting beside it inside one (slice 50c).
    ///
    /// **Deliberately not driven off the index's slug list**, unlike
    /// `findUnreferencedFiles`: a losing folder is precisely the one the index
    /// does not know about, so a sweep scoped to known slugs is the one that
    /// cannot see it — which is why a duplicated artifact folder used to be
    /// invisible to this whole report, preservation master and all.
    ///
    /// **The winner is asked of the index, not re-derived** (`/code-review`,
    /// 50c). Re-running `chooseArtifactRecord` here answers *which folder would
    /// win now*, while the index holds *which folder actually won* — and the two
    /// diverge whenever the manifest has moved since the last rebuild, which a
    /// copy arriving does not trigger. The report would then name the file the
    /// archive is serving, contradicting the one thing `.conflictingCopy`
    /// promises. The rule is the fallback for a uid the index has no row for.
    ///
    /// A losing folder's payload files are not enumerated: they are copies of
    /// payload the winner already holds, and a wall of them would bury the one
    /// path that says what happened.
    private func scanArtifactFolders(manifest: Manifest, index: ArchiveIndex)
        -> [(path: String, uid: String?)]
    {
        let artifactsRoot = rootURL.appendingPathComponent(
            ArchiveLayout.artifactsDirectoryName, isDirectory: true)
        guard
            let directories = try? FileManager.default.contentsOfDirectory(
                at: artifactsRoot, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var found: [(path: String, uid: String?)] = []
        var candidates: [ArtifactID: [String]] = [:]

        func artifact(at url: URL) -> Artifact? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? GeneaLogicJSONCoding.decoder.decode(Artifact.self, from: data)
        }

        for directory in directories {
            let isDirectory =
                (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }

            let recordURL = directory.appendingPathComponent(ArchiveLayout.recordFileName)
            let record = artifact(at: recordURL)
            if let record {
                candidates[record.uid, default: []].append(
                    ArchiveLayout.relativePath(of: recordURL, in: rootURL))
            }

            // A *file*-level conflict inside the folder — `record (conflicted
            // copy).json`, `record 2.json` — which is what Dropbox actually
            // leaves, and which the stray sweep used to file under "Stray Files"
            // (`/code-review`, 50c). Restricted to `.json`, so a preservation
            // master is never read in to find out it is not a record.
            guard
                let siblings = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for sibling in siblings
            where sibling.pathExtension.lowercased() == "json"
                && sibling.lastPathComponent != ArchiveLayout.recordFileName
            {
                guard let copy = artifact(at: sibling) else { continue }
                found.append(
                    (
                        ArchiveLayout.relativePath(of: sibling, in: rootURL),
                        // With no `record.json` beside it, this file is the only
                        // thing holding the artifact and the folder is invisible
                        // to every query — the same shape as a renamed conclusion.
                        record == nil ? copy.uid.raw : nil
                    ))
            }
        }

        let slugs = (try? index.allSlugs()) ?? [:]
        let incumbents = RecordDiscovery.recordPaths(in: manifest)
        for (uid, paths) in candidates where paths.count > 1 {
            let loaded = slugs[uid].map {
                ArchiveLayout.relativePath(
                    of: ArchiveLayout.recordURL(in: rootURL, slug: $0), in: rootURL)
            }
            let winner =
                loaded.flatMap { paths.contains($0) ? $0 : nil }
                ?? RecordDiscovery.chooseArtifactRecord(from: paths, incumbents: incumbents)
            found.append(contentsOf: paths.filter { $0 != winner }.map { ($0, nil) })
        }

        return found
    }

    /// Sweeps every `artifacts/<slug>/` folder for files that are neither
    /// `record.json` nor listed in that artifact's `files[]` — i.e. files that
    /// landed in an artifact's folder out-of-band (copied in by hand, left over
    /// from an interrupted operation, …) and that the engine doesn't know about.
    ///
    /// **Judgment call (flagged for review — the exemption set):** a naive
    /// "anything on disk that isn't in the manifest" sweep would misfire
    /// constantly, because `manifest.files` is *deliberately* scoped to artifact
    /// payload + the schema spec (see `recomputeManifestFiles`'s doc comment) —
    /// not to every structural file the format requires. Flagging those as
    /// "unreferenced" would bury real problems in noise. So this sweep is scoped
    /// the other way: it only ever looks *inside* `artifacts/<slug>/` folders
    /// (the one place "a stray file" is meaningfully surprising — finding one
    /// next to `manifest.json` at the root is a different question entirely, and
    /// not one this sweep tries to answer), and it explicitly does not flag:
    ///   - `manifest.json` (the index, not indexed content)
    ///   - every `record.json` (ditto, one per artifact)
    ///   - everything under `conclusions/` (a wholly separate evidence/conclusion
    ///     split — §2.3 — that this integrity surface, scoped to the BagIt-style
    ///     evidence payload, doesn't audit)
    ///   - `schema/<spec>.md` (deliberately IS in the manifest — see
    ///     `recomputeManifestFiles` — so it's already covered by the per-entry
    ///     checks above, not the unreferenced sweep)
    ///   - `.index/` (an explicitly-disposable, rebuildable cache — §3 — flagging
    ///     its contents as "unreferenced" would be like flagging `.git/objects`)
    ///   - any `.tmp-*`/hidden dotfile (an `AtomicIO` write-temp-then-rename
    ///     in-flight artifact; a crash mid-write can leave one behind, and it is
    ///     "stray" in a sense `repair()` should eventually sweep, but it is not
    ///     an *integrity* problem — the destination file it was headed for is
    ///     either there, intact, or the write never completed)
    /// Only a genuine extra payload file inside an artifact folder — something
    /// that *looks like* it should be tracked evidence but isn't — gets flagged.
    private func findUnreferencedFiles(manifest: Manifest, index: ArchiveIndex)
        -> [IntegrityReport.Issue]
    {
        let fm = FileManager.default
        var issues: [IntegrityReport.Issue] = []

        // `verifyIntegrity()` never throws for content problems (see its doc
        // comment) — but reading the index itself is now a SQL operation that
        // can fail. An index read failure here is treated the same as "nothing
        // to check": a genuinely broken `.index/` is `Archive.open`'s problem
        // (it would have rebuilt), not something this sweep should surface as a
        // false-positive wall of "unreferenced" files.
        guard let slugs = try? index.allSlugs(), let artifacts = try? index.allArtifacts() else {
            return issues
        }
        let artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.uid, $0) })

        for (artifactID, slug) in slugs.sorted(by: { $0.value < $1.value }) {
            guard let artifact = artifactsByID[artifactID] else { continue }
            let artifactDirectory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)

            guard
                let entries = try? fm.contentsOfDirectory(
                    at: artifactDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
            else { continue }

            let knownPaths = Set(artifact.files.map(\.path))

            for entryURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory =
                    (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard !isDirectory else { continue }

                let name = entryURL.lastPathComponent
                if name == ArchiveLayout.recordFileName { continue }
                if knownPaths.contains(name) { continue }

                let relativePath = ArchiveLayout.relativePath(of: entryURL, in: rootURL)
                issues.append(.unreferencedFile(path: relativePath))
            }
        }

        return issues
    }

    /// Attempts to repair integrity problems found by `verifyIntegrity()`
    /// (e.g. re-deriving `manifest.json` from the on-disk artifacts, restoring
    /// from a backup, …).
    ///
    /// **Flagged stub (Phase 1):** ARCHITECTURE.md §6.3 lists `repair()` in the
    /// API sketch but does not specify what "repair" means for each issue kind —
    /// a `.checksumMismatch`/`.missingFile` on a *preservation master* is data
    /// loss no automatic process should paper over silently (the fix is "restore
    /// from backup," a human/operational decision, not an engine one), whereas a
    /// `.sizeMismatch` on a derivative or an `.unreferencedFile` are much safer
    /// to auto-resolve (regenerate / re-attach-or-delete). Building a real
    /// `repair()` requires that taxonomy plus explicit user consent flows
    /// (destructive vs. safe repairs), which is app-layer/Phase-2+ design work.
    /// For now this is an honest stub — it throws rather than silently doing
    /// nothing or guessing at a destructive fix. Flagged for Opus review.
    ///
    /// - Throws: `ArchiveError.repairNotImplemented`, always.
    public func repair() throws {
        throw ArchiveError.repairNotImplemented
    }

    /// Drops and regenerates the `.index/index.sqlite` derived index by
    /// re-walking the on-disk sidecars and conclusions — the persistent analog
    /// of the old in-memory `ArchiveIndex.build(walking:)` rebuild, and the
    /// §5.1 out-of-band-edit path: "if an archive is edited out-of-band (e.g. a
    /// sidecar is hand-edited, or files are added on another machine),
    /// `rebuildIndex()` must run before queries reflect the change."
    ///
    /// Lossless: every `uid` reachable from `artifacts/*/record.json` and
    /// `conclusions/**/*.json` is re-read and re-upserted, so the post-rebuild
    /// index is identical to what `Archive.open` would produce on a fresh
    /// (no-`.index/`) open of the same on-disk state.
    ///
    /// Lossless *for the records it can read*: one that cannot be read or decoded
    /// is skipped rather than aborting the rebuild (slice 55), and its path is
    /// returned so a caller that asked for the rebuild can say so without a
    /// second query. `verifyIntegrity()` reports the same set as
    /// `.unreadableRecord`.
    ///
    /// - Returns: The archive-relative paths of every record skipped, sorted.
    @discardableResult
    public func rebuildIndex() throws -> [String] {
        try withState { manifest, index in
            try index.rebuild(
                walking: rootURL,
                manifestRecordPaths: RecordDiscovery.recordPaths(in: manifest),
                manifestVersion: manifest.schemaVersion
            ).map(\.path)
        }
    }

    /// Accepts the archive's current on-disk contents as the truth: rebuilds the
    /// index from the sidecars, then re-mints every manifest entry from the bytes
    /// that are actually there (slice 49, fork d).
    ///
    /// **This is the resolution for a legitimate out-of-band edit**, which spec
    /// §5.1 explicitly blesses: hand-edit a `record.json`, `rebuildIndex()` so
    /// queries see it — and, since slice 49, `rebaseline()` so `verifyIntegrity()`
    /// stops reporting the edit as a `checksumMismatch` it cannot tell from rot.
    /// It is also how an `.interruptedWrite` finding is cleared.
    ///
    /// **It is never automatic, and that is the point.** Nothing in `open()` or in
    /// a normal commit may do this: re-hashing a file the engine did not just
    /// write is precisely how corruption gets laundered into the manifest — the
    /// rot is re-measured, recorded as expected, and never reported again. So the
    /// engine will only do it when a human asks, in as many words.
    ///
    /// **Scoped to what the manifest alone attests** —
    /// `ArchiveLayout.isEngineAuthored` paths, and nothing else:
    ///
    /// - **Payload files are re-derived, not re-hashed**, exactly as on every
    ///   commit: a media file's authoritative checksum lives in the `record.json`
    ///   that claims it, so blessing a *changed* payload file would mean rewriting
    ///   a record's `files[]` — a different, more destructive operation, and
    ///   `repair()`'s territory if it is ever built.
    /// - **The archive's schema-spec copy is left alone too** (review finding,
    ///   49). Nothing edits it after `create`, so there is no legitimate
    ///   out-of-band edit to bless — only damage, which must keep being reported.
    ///   An earlier draft emptied `files` wholesale, which silently re-minted it.
    ///
    /// - **A record the rebuild could not read keeps its entry** (slice 59,
    ///   hand-test). "Accept what is on disk" has no meaning for bytes nothing can
    ///   read: there is no version of the record there to bless. 49 considered
    ///   this and called re-minting harmless, on the grounds that it left the
    ///   record just as invisible — true then, and untrue since 59, because that
    ///   entry is now also the **proof** that a restore from the preserved copy is
    ///   byte-exact. Re-minting it recorded the corrupt bytes as the baseline, so
    ///   the copy no longer matched and a provable one-click repair silently
    ///   became the labelled fallback, explained as version skew it wasn't. This
    ///   is the same trap 58's review found from the other side: a call that was
    ///   safely conservative stopped being safe once something started making a
    ///   claim from it.
    ///
    /// So a rebaselined archive still reports bit rot in a preservation master,
    /// still reports a mangled spec, and can still repair a damaged record from
    /// the copy the index kept.
    /// **Stop waiting for one named file** — the way out of the state where the
    /// manifest expects a version that is never going to arrive (slice 50d).
    ///
    /// After 50 and 50b, one shape survives that no evidence decides: a provider
    /// ate one machine's edit outright, a sender went away mid-delivery, or an
    /// `.index/` was recreated so the superseded rows are gone and the merge
    /// degraded to taking the arriving manifest whole. In all three the archive
    /// reports `.awaitingDelivery` for ever, `manifestDeliveryLooksComplete`
    /// stays false, the witness never settles, and the record is frozen against
    /// every further edit — with the engine's own advice forbidding `rebaseline`,
    /// the one operation that would clear it. The only evidence available is
    /// *time without progress*, which is 61's stall heuristic and a hedge rather
    /// than a diagnosis. So this is a verb a human invokes, never a sweep.
    ///
    /// **Dropping the entry is the whole implementation**, exactly as in
    /// `rebaseline()` but for one path: `withState`'s closing `commitManifest`
    /// recomputes, and with nothing left to carry forward it either **mints the
    /// entry from the file that is actually here** (the file is present — the
    /// common case, where our version becomes the version of record) or
    /// **contributes nothing at all** (the file never arrived, so there is
    /// nothing to describe and the expectation simply goes). `awaitedPaths` does
    /// not put it back, because it reads the entries the manifest carried *into*
    /// this recompute and this one is no longer among them.
    ///
    /// **It is recoverable, and that is what makes it offerable where
    /// `rebaseline` is not.** A version that lands afterwards is walked into the
    /// index by the next rebuild and re-minted by the next mutation; nothing is
    /// deleted and no file is touched. `rebaseline` is blunt by comparison — it
    /// re-mints from disk archive-wide — which is why there is no `--all` here
    /// and never should be (fork d).
    ///
    /// **It refuses anything that is not actually awaited** (fork b), including
    /// — and especially — a disagreement no delivery covers, which is damage
    /// wearing this verb as a disguise. See `ArchiveError.notAwaitingDelivery`.
    /// It is deliberately **not** gated on how long the wait has lasted: elapsed
    /// time would dress 61's hedge up as a diagnosis, and a slow link is
    /// structurally indistinguishable from a stopped one. 61's escalation is the
    /// *prompt* for this call, never its licence.
    ///
    /// - Parameter path: The archive-relative path to stop waiting for.
    public func abandonDelivery(path: String) throws {
        try withState { manifest, _ in
            guard let entry = manifest.files.first(where: { $0.path == path }) else {
                throw ArchiveError.notAwaitingDelivery(path: path, reason: .notInManifest)
            }
            // **Only what the manifest itself authors** — the same scope
            // `rebaseline()` is confined to, for the same reason and now for a
            // second one. A payload entry is *re-derived* every commit from the
            // `record.json` that claims the file (`payloadEntries`), so dropping
            // it here achieves exactly nothing: the closing recompute puts it
            // straight back, and before this guard the call still wrote its note
            // — leaving `verify` reporting the path as both awaited and
            // abandoned, for ever, and accepting the request again every time
            // (`/code-review`). The honest remedy for a payload that is never
            // coming is to take the claim out of the record that makes it
            // (`detachFile`), which is a different and more destructive verb.
            guard ArchiveLayout.isEngineAuthored(relativePath: path) else {
                throw ArchiveError.notAwaitingDelivery(path: path, reason: .notManifestAuthored)
            }
            guard !fileMatches(entry) else {
                throw ArchiveError.notAwaitingDelivery(path: path, reason: .fileMatches)
            }
            // **Ahead of the coverage test, because `verifyIntegrity()` puts it
            // there** (`/code-review`). Both can be true at once, and the
            // sentinel is the more specific fact: *this* archive's own write died
            // here, so the local bytes may be half a commit rather than a good
            // older version of someone else's record. Verify reports that as
            // `.interruptedWrite` and points at `rebaseline()`; a gate that
            // skipped it would let this verb bless a half-written file as the
            // version of record and bypass that warning entirely.
            guard !interruptedWriteSuspectedLocked else {
                throw ArchiveError.notAwaitingDelivery(path: path, reason: .interruptedWrite)
            }
            // **The anti-laundering gate.** `verifyIntegrity()` would call this
            // path `.awaitingDelivery` only where a delivery covers the entry;
            // anywhere else the same on-disk state is `.missingFile` or a
            // checksum mismatch — damage. Asking the *same* question here rather
            // than a cheaper approximation is what keeps this verb from becoming
            // a per-path `rebaseline` (fork b).
            guard deliveryCoverageLocked().covers(entry) else {
                throw ArchiveError.notAwaitingDelivery(path: path, reason: .notADelivery)
            }
            manifest.files.removeAll { $0.path == path }
            abandonedThisMutation.insert(path)
        }
    }

    /// Whether the file at `entry.path` is exactly what the manifest records.
    ///
    /// Size first, because it settles most cases for one `stat`; the hash only
    /// where the sizes agree. One file, so hashing here costs nothing like
    /// `verifyIntegrity()` — and the hash is required: the state slice 50
    /// reproduces is two versions of one record that very often agree on length.
    private func fileMatches(_ entry: ManifestEntry) -> Bool {
        let url = rootURL.appendingPathComponent(entry.path)
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber, size.int64Value == entry.byteLength
        else { return false }
        return (try? Checksum.sha256Hex(ofFileAt: url)) == entry.sha256
    }

    public func rebaseline() throws {
        try withState { manifest, index in
            // The rebuild names the records it could not read, which are exactly
            // the entries to leave alone below: that entry is what proves a restore
            // from the preserved copy exact (59), so blessing bytes nothing can read
            // would destroy the one repair on offer.
            //
            // **Only the undecodable ones** (slice 64, hand-test). An older-format
            // record is skipped through the same list and none of that applies to
            // it — the file reads, and Repair refuses it regardless — so leaving its
            // entry made *Accept Current Contents* silently do nothing for that one
            // file while the button was offered for it.
            //
            // **And a record whose sidecar vanished, for the same reason** (58c,
            // second `/code-review`). Its copy is the repair on offer, and since
            // 58c a dropped entry is what lets the next rebuild prune that copy as
            // a deletion — so a rebaseline asked for to bless one unrelated hand
            // edit would have cost every lost record its last copy, archive-wide,
            // with nothing in the dialog saying so. Its entry stays; accepting the
            // loss is discarding the copy, one record at a time.
            let skipped = try index.rebuild(
                walking: rootURL,
                manifestRecordPaths: RecordDiscovery.recordPaths(in: manifest),
                manifestVersion: manifest.schemaVersion)
            let skippedPaths = Set(skipped.map(\.path))
            let kept = Set(skipped.filter { $0.reason == .undecodable }.map(\.path))
                .union(try index.preservedRecordPaths().filter { !skippedPaths.contains($0) })
            // Dropping the authored entries is the whole implementation:
            // `withState`'s closing `commitManifest` recomputes the list, and with
            // nothing left to carry forward it mints each of them from disk. An
            // entry left here is carried forward verbatim instead — the same
            // mechanism `recomputeManifestFiles` uses for an unreadable record on
            // every other commit (55), which this call had been the one exception
            // to.
            manifest.files.removeAll {
                ArchiveLayout.isEngineAuthored(relativePath: $0.path)
                    && !kept.contains($0.path)
            }
            resolveInterruptedWrite()
        }
    }
}

/// What the rebuilt index says the archive holds — the evidence that decides
/// whether a manifest entry the disk disagrees with is **a write that died before
/// its manifest** rather than damage (slice 65, fork c).
///
/// 49's rule covered one shape: an engine-authored file whose bytes moved. Under
/// the sentinel two more say the same thing, and both used to read as damage:
///
/// - **an entry that is missing and that nothing the archive holds still
///   names** — a removal, a detach or a replace that unlinked before the manifest
///   caught up. One the index still references stays `.missingFile`: the
///   sentinel does not explain bytes the archive itself says should be there.
/// - **a payload whose sidecar already records the bytes on disk** — the record
///   caught up and the manifest did not. Unreachable by a cut since `replaceFile`
///   stopped overwriting in place; kept for an archive that crashed before that.
struct InterruptedWriteEvidence {
    /// Every path a record the index holds still names, readable or not.
    let referenced: Set<String>
    /// The payload entries the sidecars author, by archive-relative path.
    let sidecarEntries: [String: ManifestEntry]

    /// Whether `entry`'s disagreement with the disk is explained. `actualSHA256`
    /// is `nil` for a file that is absent.
    func explains(_ entry: ManifestEntry, actualSHA256: String?) -> Bool {
        guard let actual = actualSHA256 else { return !referenced.contains(entry.path) }
        guard actual != entry.sha256 else { return false }
        if ArchiveLayout.isEngineAuthored(relativePath: entry.path) { return true }
        return sidecarEntries[entry.path]?.sha256 == actual
    }
}
