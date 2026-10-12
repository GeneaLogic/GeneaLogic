import Foundation
import GeneaLogicModel

/// Putting back a record the archive can no longer read, from the copy the index
/// still holds (slice 59).
///
/// **Why this is now offerable, when 56 deliberately offered nothing.** A record
/// that failed to decode has its uid inside the file that failed, so every
/// uid-addressed mutation is unavailable *by construction* — which is why the
/// placeholder row's only honest affordance was Reveal in Finder. Two things
/// changed that in one specific case: 58 keeps the last index row of a record the
/// rebuild had to skip, and that row is the sidecar's own bytes; and since 49 the
/// manifest holds the `sha256` of those bytes. So the archive can put the file
/// back *and prove the restoration is exact*, which is a different offer from
/// regenerating something plausible from a cache.
extension Archive {

    /// What a repair of the record at `path` would do — or `nil` when there is
    /// nothing to offer.
    ///
    /// **`nil` is a normal answer, not an error** (58's stated limit). The copy
    /// lives in `.index/`, so it survives the dirty-sentinel rebuild and an
    /// explicit Rebuild Index, but not a missing, corrupt or schema-stale index —
    /// those unlink the database first. A record that never decoded on any rebuild
    /// (a corrupt file dropped in from elsewhere) was never in the index either.
    /// A host must therefore ask rather than infer a repair from the damage: a row
    /// that offers a repair it cannot perform is the lie 56 was careful not to
    /// tell.
    public func repairPlan(forRecordAt path: String) throws -> RecordRepairPlan? {
        try withReadState { manifest, index in
            guard let preserved = try preservedCopy(atPath: path, index: index) else { return nil }
            return plan(
                for: preserved, at: path,
                recordedSHA256: manifest.files.first { $0.path == path }?.sha256)
        }
    }

    /// The same answer for several paths at once — **the call a host with a list
    /// should make** (review finding, 59).
    ///
    /// `repairPlan(forRecordAt:)` looks cheap and is not: `withReadState` re-reads
    /// and decodes the whole `manifest.json` (deliberately — a reader's manifest
    /// staleness is otherwise unbounded, §10.5), so asking it once per damaged
    /// record parses the manifest once per damaged record. Every caller with more
    /// than one path in hand — the app's placeholder rows, `genea verify`'s
    /// report — has exactly that shape, so the plural form reads the manifest
    /// once and indexes it once.
    ///
    /// Paths with nothing to restore are simply absent from the result, which is
    /// the same "ask, don't assume" contract as the singular call.
    public func repairPlans(forRecordsAt paths: [String]) throws -> [String: RecordRepairPlan] {
        try withReadState { manifest, index in
            let recorded = Dictionary(
                manifest.files.lazy.map { ($0.path, $0.sha256) },
                uniquingKeysWith: { first, _ in first })
            var plans: [String: RecordRepairPlan] = [:]
            for path in paths {
                guard let preserved = try preservedCopy(atPath: path, index: index) else {
                    continue
                }
                plans[path] = plan(
                    for: preserved, at: path, recordedSHA256: recorded[path])
            }
            return plans
        }
    }

    /// The preserved bytes for `path`, if the path is one a repair could write to
    /// at all. The shape check comes first so that a path of any other form is
    /// "nothing to restore" rather than a lookup nobody can act on.
    ///
    /// **A record skipped for any reason other than damage has nothing to
    /// restore either** (slice 64, fork e). A straggler at an older format
    /// version reads perfectly and keeps a preserved copy like any skipped
    /// record — but that copy is an *earlier* version of an intact file, and
    /// offering it would be offering a downgrade. One comparison, here, so the
    /// plan and the mutation agree.
    private func preservedCopy(
        atPath path: String, index: ArchiveIndex
    ) throws -> (uid: String, json: Data)? {
        guard RepairTarget(path: path) != nil, try isDamage(path, index: index) else {
            return nil
        }
        return try index.preservedRecord(atPath: path)
    }

    /// Whether the finding on `path`, if any, is one a repair may answer.
    private func isDamage(_ path: String, index: ArchiveIndex) throws -> Bool {
        try index.unreadableRecordReason(atPath: path) != .olderFormat
    }

    /// The plan, from state already in hand. Every caller builds it the same way so
    /// that what a host was shown and what the mutation decides cannot diverge —
    /// though `repairRecord` re-derives it under the write lock rather than
    /// trusting one it was handed, because the file may have changed since.
    ///
    /// **One deliberate exception:** a folder on the path that a file has taken
    /// (slice 71, fork a). The plan does not look for it, so Restore and Delete
    /// stay offered, and both refuse with `recordPathBlocked`, naming the file —
    /// an offer the user can act on once it is moved, rather than a row with no
    /// way out and no reason given.
    private func plan(
        for preserved: (uid: String, json: Data), at path: String, recordedSHA256: String?
    ) -> RecordRepairPlan {
        RecordRepairPlan(
            path: path,
            uid: preserved.uid,
            restoredSHA256: Checksum.sha256Hex(of: preserved.json),
            recordedSHA256: recordedSHA256,
            replacesFileOnDisk: FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent(path).path),
            recordLabel: RepairTarget(path: path).flatMap { try? $0.decode(preserved.json) }?
                .label)
    }

    /// Restores the record at `path` from the preserved copy, moving whatever is
    /// there now into `.damaged/` first.
    ///
    /// **What it restores is the last version *GeneaLogic wrote*,** which is the
    /// sentence a host has to put in front of a human before calling this (fork
    /// d): if someone hand-edited the sidecar and the edit was good, this discards
    /// it. What makes that survivable rather than merely disclosed is the
    /// quarantine — the bytes found in place are moved aside, never overwritten,
    /// so the case where the "damage" was an edit the user meant is recoverable by
    /// hand.
    ///
    /// **`acceptingInexactRestore` is fork (a)'s gate, and version skew is what it
    /// guards.** The preserved bytes are this version's encoding of the record; if
    /// the sidecar was written by a *newer* GeneaLogic carrying fields this
    /// version doesn't model, decode dropped them and the bytes no longer hash to
    /// what the manifest recorded. Restoring is then a lossy operation on a file
    /// that may have been perfectly good, so it is refused unless a caller says
    /// otherwise in as many words — the same shape as `rebaseline()`, and for the
    /// same reason.
    ///
    /// A crash between the quarantine and the write leaves no sidecar, the copy
    /// still preserved (58 prunes on the uid being live again, and it isn't), and
    /// the dirty sentinel set: re-running the repair is what fixes it.
    @discardableResult
    public func repairRecord(
        atPath path: String, acceptingInexactRestore: Bool = false
    ) throws -> RecordRepairOutcome {
        try withState { manifest, index in
            try restoreLocked(
                atPath: path, acceptingInexactRestore: acceptingInexactRestore,
                manifest: manifest, index: index
            ).outcome
        }
    }

    /// `repairRecord`'s body, for a caller already inside `withState` — and handing
    /// back the decoded record, which `deleteVanishedRecord` needs to address the
    /// deletion by uid.
    private func restoreLocked(
        atPath path: String, acceptingInexactRestore: Bool, manifest: Manifest,
        index: ArchiveIndex
    ) throws -> (outcome: RecordRepairOutcome, record: RepairedRecord) {
        // The finding is from the last rebuild; the file may have been
        // replaced since — by a sync delivery from a newer GeneaLogic, which
        // a repair would carry off to `.damaged/` and write this build's
        // older copy over (slice 70, fork b). Asked before the finding is,
        // so the refusal names what the file is now (`/code-review`, 70).
        try Migration.refuseIfAhead(
            recordAt: rootURL.appendingPathComponent(path), path: path)
        guard try isDamage(path, index: index) else {
            throw ArchiveError.repairNotForOlderFormat(path: path)
        }
        guard let target = RepairTarget(path: path),
            let preserved = try index.preservedRecord(atPath: path)
        else { throw ArchiveError.noPreservedCopy(path: path) }
        // A folder replaced by a file reads as gone (`isGone`), so the record is
        // offered — but the write would fail under it, after the plan said yes
        // (slice 71). Named here, before anything moves.
        if let blocker = blockingFile(onPath: path) {
            throw ArchiveError.recordPathBlocked(path: path, by: blocker)
        }

        let plan = plan(
            for: preserved, at: path,
            recordedSHA256: manifest.files.first { $0.path == path }?.sha256)
        guard !plan.requiresExplicitAcceptance || acceptingInexactRestore else {
            throw ArchiveError.repairNotByteExact(path: path)
        }

        // Decoded *before* anything moves: a copy this version cannot read is
        // a copy it must not act on, and finding that out after the user's
        // file has been carried off to `.damaged/` would be a repair that
        // took the archive apart and put nothing back.
        let record = try target.decode(preserved.json)

        let url = rootURL.appendingPathComponent(path)
        let quarantined = try quarantineDamagedFile(at: url, uid: preserved.uid)
        try writeAuthoredData(preserved.json, to: url)
        try record.store(in: index, root: rootURL)

        // The copy has done its job, and the finding it explained is answered.
        // Both are dropped here rather than left for the next rebuild to
        // notice, so the banner and the placeholder row go when the repair
        // does — a row still saying "unreadable record" about a file that now
        // reads is the same lie in the other direction.
        try index.discardPreservedRecord(atPath: path)
        try index.clearUnreadableRecord(atPath: path)

        return (
            RecordRepairOutcome(
                path: path, uid: preserved.uid, wasByteExact: plan.isByteExact,
                quarantinedPath: quarantined),
            record
        )
    }

    /// Deletes a record whose file is gone — **by putting it back from the copy
    /// and then deleting it the ordinary way** (slice 58d, fork e as settled on the
    /// hand-test). The hosts' Delete on a missing record.
    ///
    /// **Why not just drop the copy.** That was the first version, and it could not
    /// be undone: the copy and the manifest checksum that proves a restore exact
    /// were both gone, and putting them back would have meant minting a manifest
    /// entry for a file that isn't there. Going through the ordinary deletion
    /// instead gives every kind its existing undo for nothing — the result is the
    /// value each kind's own restore takes — and an artifact goes to the Trash,
    /// recoverable across sessions. It also retires the restriction the first
    /// version needed: an artifact whose masters are still in its folder no longer
    /// strands them, because the whole folder goes to the Trash with the record.
    ///
    /// **Two commits, deliberately.** The ordinary deletions each take the write
    /// lock, which is not recursive. A crash between them leaves the record
    /// restored — exactly what Restore would have done, and a state the user can
    /// delete from normally.
    ///
    /// Throws `recordNotMissing` when something is at `path` (an unreadable
    /// record, or a file that came back since a host looked — checked under the
    /// write lock), `recordPathBlocked` when a file stands where a folder on it
    /// should be, and `noPreservedCopy` when there is nothing to put back. A copy
    /// that is not byte-exact is accepted: nothing on disk is being replaced, and
    /// it is on its way to being deleted.
    @discardableResult
    public func deleteVanishedRecord(atPath path: String) throws -> DeletedRecord {
        let record = try withState { manifest, index in
            guard ArchiveIndex.isGone(rootURL.appendingPathComponent(path)) == true else {
                throw ArchiveError.recordNotMissing(path: path)
            }
            return try restoreLocked(
                atPath: path, acceptingInexactRestore: true, manifest: manifest, index: index
            ).record
        }
        switch record {
        case .artifact(let artifact, _):
            return .artifact(artifact.uid, try removeArtifact(artifact.uid))
        case .person(let person): return .person(try removePerson(person.uid))
        case .relationship(let relationship):
            return .relationship(try removeRelationship(relationship.uid))
        case .link(let link): return .link(try unlink(link.uid))
        case .dismissal(let dismissal): return .dismissal(try removeDismissal(dismissal.uid))
        }
    }

    /// What `deleteVanishedRecord` removed — each case the value that kind's own
    /// restore takes, so a host's undo is the one it already has.
    public enum DeletedRecord: Sendable {
        case artifact(ArtifactID, ArtifactDeletion)
        case person(Person)
        case relationship(Relationship)
        case link(EvidenceLink)
        case dismissal(Dismissal)
    }

    /// The archive-relative path of whatever stands where a folder on `path`
    /// should be, or `nil` when every folder on it is one or is not there yet.
    /// A symlink to a folder is a folder, as the write would follow it; a dangling
    /// one is in the way (`/code-review`): `fileExists` follows it to nothing, but
    /// the write cannot create a folder where it is.
    private func blockingFile(onPath path: String) -> String? {
        let fm = FileManager.default
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(component) : "\(prefix)/\(component)"
            let at = rootURL.appendingPathComponent(prefix).path
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: at, isDirectory: &isDirectory) {
                if isDirectory.boolValue { continue }
                return prefix
            }
            return (try? fm.destinationOfSymbolicLink(atPath: at)) == nil ? nil : prefix
        }
        return nil
    }

    /// Moves the file at `url` into `.damaged/<uid>-<timestamp>.json`, returning
    /// its archive-relative path — or `nil` when there was no file there (a
    /// sidecar that vanished rather than one that broke; there is nothing to keep).
    ///
    /// The name carries the uid and the moment rather than the original path,
    /// because two records can share a file name — every artifact sidecar is
    /// `record.json` — and the uid is the one identifier that doesn't collide. A
    /// second repair of the same record in the same second gets a counter; the
    /// timestamp is UTC so the ordering reads correctly across a machine that
    /// travels.
    private func quarantineDamagedFile(at url: URL, uid: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let directory = ArchiveLayout.damagedDirectory(in: rootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = ArchiveLayout.keptFileURL(in: directory, stem: uid, extension: "json")

        // A rename within the package, so it is atomic and cannot half-copy a
        // file whose whole value is being the bytes that were there.
        try FileManager.default.moveItem(at: url, to: destination)
        WriteCheckpoint.reached("moved", at: destination)
        return ArchiveLayout.relativePath(of: destination, in: rootURL)
    }

    // MARK: - Types

    /// What restoring the record at `path` would put back, and whether it can be
    /// proved exact.
    public struct RecordRepairPlan: Sendable, Equatable {
        /// Archive-relative path of the record that would be restored.
        public let path: String

        /// The record's `uid`, as the index recorded it — a `String` for the same
        /// reason `PreservedRecord.uid` is one: the kind is only knowable from the
        /// path, and this refuses to guess.
        public let uid: String

        /// The checksum of the bytes that would be written.
        public let restoredSHA256: String

        /// What the manifest records for `path` — `nil` for a path it has no entry
        /// for, which is an archive written before slice 49 put authored checksums
        /// in the manifest.
        public let recordedSHA256: String?

        /// Whether there is a file at `path` for the restore to replace — `false`
        /// for a sidecar that vanished rather than one that broke.
        public let replacesFileOnDisk: Bool

        /// Whether the restoration can be **proved** byte-exact: the bytes to be
        /// written are the bytes the manifest says the file had.
        ///
        /// A missing `recordedSHA256` is deliberately *not* exact. There is
        /// nothing to check against, and "we cannot tell" belongs with the case
        /// that needs saying out loud rather than with the one that can promise
        /// something.
        public var isByteExact: Bool { recordedSHA256 == restoredSHA256 }

        /// Whether `repairRecord` will refuse without
        /// `acceptingInexactRestore` — fork (a)'s gate.
        ///
        /// **It asks whether anything is being replaced, not just whether the
        /// bytes check out**, because a restore that overwrites nothing has
        /// nothing to lose. That is not a softening of the gate; it is the rule
        /// 58's drift guard already applies at the other end of the same
        /// question — "absent is a repair, not a clobber — there is nothing left
        /// to destroy." Without it the case with the strongest claim on a repair
        /// is the one refused it: a sidecar *deleted* out of band keeps its copy
        /// (58) but loses its manifest entry, because the carry-forward rule has
        /// no file to describe — so an exactness test alone turned "your record
        /// was deleted and we still have it" into a warning about version skew,
        /// for an overwrite that cannot happen.
        public var requiresExplicitAcceptance: Bool { replacesFileOnDisk && !isByteExact }

        /// What the saved copy calls itself — an artifact's title, a person's
        /// display name — or `nil` for the kinds with no name of their own, and
        /// for a copy this version cannot decode (slice 58d, fork d).
        ///
        /// **The one place a damaged record has a name.** 56's placeholder could
        /// show only the path, because the name was inside the file that failed.
        /// The copy is the same record, and it decodes — so a row deciding between
        /// Restore and Discard can say *which* record, rather than `PER-0192…`.
        /// Display only: identity is still `path` and `uid`.
        public let recordLabel: String?

        /// Whether a host may offer to delete the record instead (slice 58d) —
        /// only when its file is **gone**. An unreadable record's file is still
        /// there; deleting it is not this slice's offer. `deleteVanishedRecord`
        /// re-checks under the write lock.
        public var isDeletable: Bool { !replacesFileOnDisk }

        public init(
            path: String, uid: String, restoredSHA256: String, recordedSHA256: String?,
            replacesFileOnDisk: Bool, recordLabel: String? = nil
        ) {
            self.path = path
            self.uid = uid
            self.restoredSHA256 = restoredSHA256
            self.recordedSHA256 = recordedSHA256
            self.replacesFileOnDisk = replacesFileOnDisk
            self.recordLabel = recordLabel
        }
    }

    /// What a completed repair did.
    public struct RecordRepairOutcome: Sendable, Equatable {
        public let path: String
        public let uid: String

        /// Whether the restoration was proved exact — `false` only on a repair the
        /// caller explicitly accepted as inexact.
        public let wasByteExact: Bool

        /// Where the file found in place was moved to, archive-relative; `nil`
        /// when there was no file there to keep.
        public let quarantinedPath: String?

        public init(path: String, uid: String, wasByteExact: Bool, quarantinedPath: String?) {
            self.path = path
            self.uid = uid
            self.wasByteExact = wasByteExact
            self.quarantinedPath = quarantinedPath
        }
    }
}

/// Which kind of record a repairable path names, and how to decode and store one.
///
/// The path is the only thing that says what kind a preserved copy is — its row
/// holds bytes and a uid, deliberately, so that nothing can mistake it for a live
/// record. These five shapes are exactly the ones `stagePreservationCandidates`
/// reconstructs, so a path of any other shape has no copy to restore and is
/// reported as such rather than guessed at.
private enum RepairTarget {
    case artifact(slug: String)
    case person
    case relationship
    case link
    case dismissal

    init?(path: String) {
        if let slug = ArchiveLayout.artifactSlug(ofRecordPath: path) {
            self = .artifact(slug: slug)
            return
        }
        let components = path.split(separator: "/").map(String.init)
        switch components.first {
        case ArchiveLayout.conclusionsDirectoryName
        where components.count == 3 && components[2].hasSuffix(".json"):
            switch "\(components[0])/\(components[1])" {
            case ArchiveLayout.personsDirectoryRelativePath: self = .person
            case ArchiveLayout.relationshipsDirectoryRelativePath: self = .relationship
            case ArchiveLayout.linksDirectoryRelativePath: self = .link
            case ArchiveLayout.dismissalsDirectoryRelativePath: self = .dismissal
            default: return nil
            }
        default:
            return nil
        }
    }

    func decode(_ json: Data) throws -> RepairedRecord {
        let decoder = GeneaLogicJSONCoding.decoder
        switch self {
        case .artifact(let slug):
            return .artifact(try decoder.decode(Artifact.self, from: json), slug: slug)
        case .person:
            return .person(try decoder.decode(Person.self, from: json))
        case .relationship:
            return .relationship(try decoder.decode(Relationship.self, from: json))
        case .link:
            return .link(try decoder.decode(EvidenceLink.self, from: json))
        case .dismissal:
            return .dismissal(try decoder.decode(Dismissal.self, from: json))
        }
    }
}

/// A decoded preserved copy, on its way back into the index.
private enum RepairedRecord {
    case artifact(Artifact, slug: String)
    case person(Person)
    case relationship(Relationship)
    case link(EvidenceLink)
    case dismissal(Dismissal)

    /// `RecordRepairPlan.recordLabel`. Only the two kinds with a name of their
    /// own: a relationship, link or dismissal is identified by the records it
    /// joins, and naming those needs lookups a plan has no business making.
    var label: String? {
        switch self {
        case .artifact(let artifact, _): artifact.title
        case .person(let person): person.displayName
        case .relationship, .link, .dismissal: nil
        }
    }

    /// Puts the record back in the live tables, so it is browsable again without
    /// waiting for a rebuild — the targeted equivalent of what the rebuild's walk
    /// would have done had it been able to read the file.
    func store(in index: ArchiveIndex, root: URL) throws {
        switch self {
        case .artifact(let artifact, let slug):
            try index.upsert(
                artifact, slug: slug,
                artifactDirectory: ArchiveLayout.artifactDirectory(in: root, slug: slug))
        case .person(let person): try index.upsert(person)
        case .relationship(let relationship): try index.upsert(relationship)
        case .link(let link): try index.upsert(link)
        case .dismissal(let dismissal): try index.upsert(dismissal)
        }
    }
}
