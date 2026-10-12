import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 50d — nothing is coming, and the way out.
///
/// The state slices 50 and 50b deliberately left standing: `manifest.files`
/// expects a version that never arrives, and **no evidence decides it**. The
/// archive then reports `awaitingDelivery` for ever, the witness never settles,
/// and the record is frozen against every further edit — with the engine's own
/// advice forbidding `rebaseline`, the one operation that would clear it.
///
/// These pin the verb that clears it, the refusals that keep it from becoming a
/// per-path `rebaseline`, and the recoverability that makes it safe to offer at
/// all.
@Suite struct AbandonDeliveryTests {

    // MARK: - The rig (the same shape 50b's tests use)

    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }


    private func manifest(at root: URL) throws -> Manifest {
        try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
    }

    private func path(of person: PersonID) -> String {
        "conclusions/persons/\(person.raw).json"
    }

    private func addName(_ surname: String, to person: PersonID, in archive: Archive) throws {
        try archive.updatePerson(person) {
            $0.names.append(PersonName(type: .married, given: "Ada", surname: surname))
        }
    }

    /// **The sender went away mid-delivery, and the file is here in its old
    /// version.** Other edits a record both machines hold; only `manifest.json`
    /// makes the crossing. Mine then expects a version of that record that
    /// nothing will ever bring, while holding a perfectly good older one.
    private func stageDeliveryOfAnEditThatNeverLands() throws -> (
        mine: URL, other: URL, awaited: PersonID
    ) {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let ada = try otherArchive.addPerson(.sample(given: "Ada", surname: "Baseline")).uid

        let mine = try clone(other)
        try addName("OTHER-EDIT", to: ada, in: otherArchive)
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        return (mine, other, ada)
    }

    /// **The same, for a record that does not exist here at all.** Other creates
    /// a person and only the manifest arrives, so mine expects a file that has
    /// never been on this disk.
    private func stageDeliveryOfACreationThatNeverLands() throws -> (
        mine: URL, other: URL, awaited: PersonID
    ) {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        _ = try otherArchive.addPerson(.sample(given: "Ada", surname: "Baseline"))

        let mine = try clone(other)
        let created = try otherArchive.addPerson(.sample(given: "Ada", surname: "Newcomer")).uid
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        return (mine, other, created)
    }

    // MARK: - The state, and that it really is stuck

    @Test func aDeliveryThatNeverArrivesStaysAwaitedForEver() throws {
        let staged = try stageDeliveryOfAnEditThatNeverLands()
        let archive = try Archive.open(at: staged.mine)

        #expect(try !archive.verifyIntegrity().isClean)
        #expect(
            try archive.verifyIntegrity().issues.contains {
                if case .awaitingDelivery(let p) = $0 { return p == self.path(of: staged.awaited) }
                return false
            })
        // And an ordinary mutation does not clear it — the entry is carried
        // forward on every commit, which is what makes this permanent rather
        // than merely reported once. This is also the negative half of "the
        // re-mint is reachable only through the verb".
        _ = try archive.addPerson(.sample(given: "Ada", surname: "Later"))
        #expect(try !archive.verifyIntegrity().isClean, "a normal write must not launder this")
        let files = try manifest(at: staged.mine).files.map(\.path)
        #expect(files.contains(path(of: staged.awaited)))
    }

    // MARK: - Fork (a) — what the verb does

    /// **The file is present: its entry is re-minted from disk.** This machine's
    /// copy becomes the version of record, the archive settles, and nothing is
    /// deleted.
    @Test func abandoningAPresentFileReMintsItFromDisk() throws {
        let staged = try stageDeliveryOfAnEditThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        let awaited = path(of: staged.awaited)

        try archive.abandonDelivery(path: awaited)

        #expect(try archive.verifyIntegrity().isClean)
        #expect(!archive.deliveryIsInFlight, "the witness must be able to settle now")
        let entry = try #require(try manifest(at: staged.mine).files.first { $0.path == awaited })
        let onDisk = try Checksum.sha256Hex(
            ofFileAt: staged.mine.appendingPathComponent(awaited))
        #expect(entry.sha256 == onDisk, "the entry must describe the file that is here")
        // The record itself is untouched — still ours, still readable.
        let person = try #require(try archive.person(withID: staged.awaited))
        #expect(person.names.allSatisfy { $0.surname != "OTHER-EDIT" })
    }

    /// **The file never arrived: the expectation is dropped.** There is nothing
    /// on disk to describe, so the entry simply goes.
    @Test func abandoningAnAbsentFileDropsTheEntry() throws {
        let staged = try stageDeliveryOfACreationThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        let awaited = path(of: staged.awaited)

        try archive.abandonDelivery(path: awaited)

        #expect(try archive.verifyIntegrity().isClean)
        let files = try manifest(at: staged.mine).files.map(\.path)
        #expect(!files.contains(awaited))
    }

    /// **A later mutation does not put it back.** `awaitedPaths` re-adds an entry
    /// with no file on every commit, which is right for a delivery and is exactly
    /// what would undo this one.
    @Test func aLaterMutationDoesNotResurrectAnAbandonedEntry() throws {
        let staged = try stageDeliveryOfACreationThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        try archive.abandonDelivery(path: path(of: staged.awaited))

        _ = try archive.addPerson(.sample(given: "Ada", surname: "Later"))

        let files = try manifest(at: staged.mine).files.map(\.path)
        #expect(!files.contains(path(of: staged.awaited)))
        #expect(try archive.verifyIntegrity().isClean)
    }

    // MARK: - An index recreated under a stuck delivery

    /// **A recreated `.index/` does not reach this verb, and that is 60b's rule
    /// working.** 50d's spec first listed it as a third way into the stuck state, on
    /// the reasoning that losing the superseded rows degrades 50's merge to
    /// taking the arriving manifest whole. It does — but an index with no
    /// witness at all reads as `.unknown`, which 60b deliberately routes to
    /// *damage* rather than to an arrival, so the disagreement is reported as a
    /// checksum mismatch and the user is told to verify rather than to wait.
    ///
    /// So this state was never one where the archive says "wait for a delivery",
    /// and the verb refuses it — correctly, because blessing local bytes against
    /// a manifest nothing vouches for is `rebaseline`'s decision, made per
    /// archive and behind its own warning. Pinned here so the claim in the spec
    /// is not carried forward as though it had been built.
    @Test func aRecreatedIndexReportsDamageAndIsRefused() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let mineEdits = try otherArchive.addPerson(.sample(given: "Ada", surname: "Mine")).uid
        let theirs = try otherArchive.addPerson(.sample(given: "Ada", surname: "Theirs")).uid

        let mine = try clone(other)
        let mineArchive = try Archive.open(at: mine)
        try addName("MY-EDIT", to: mineEdits, in: mineArchive)

        try FileManager.default.removeItem(
            at: mine.appendingPathComponent(ArchiveLayout.indexDirectoryName))

        try addName("OTHER-EDIT", to: theirs, in: otherArchive)
        try TestSupport.deliver(["manifest.json", path(of: theirs)], from: other, to: mine)

        let reopened = try Archive.open(at: mine)
        let awaited = path(of: mineEdits)
        #expect(
            try !reopened.verifyIntegrity().issues.contains {
                if case .awaitingDelivery(let p) = $0 { return p == awaited }
                return false
            }, "with no witness this is damage, not an arrival — 60b fork (b)")

        #expect(
            throws: ArchiveError.notAwaitingDelivery(
                path: awaited, reason: .notADelivery)
        ) {
            try reopened.abandonDelivery(path: awaited)
        }
    }

    // MARK: - Fork (b) — the refusals

    @Test func refusesAPathTheManifestDoesNotName() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        #expect(
            throws: ArchiveError.notAwaitingDelivery(
                path: "conclusions/persons/PER-nope.json", reason: .notInManifest)
        ) {
            try archive.abandonDelivery(path: "conclusions/persons/PER-nope.json")
        }
    }

    @Test func refusesAPathWhoseFileAlreadyMatches() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let ada = try archive.addPerson(.sample(given: "Ada", surname: "Fine")).uid
        #expect(
            throws: ArchiveError.notAwaitingDelivery(
                path: path(of: ada), reason: .fileMatches)
        ) {
            try archive.abandonDelivery(path: self.path(of: ada))
        }
    }

    /// **The anti-laundering gate, and the reason fork (b) exists.** A record
    /// damaged out of band disagrees with the manifest exactly as an undelivered
    /// one does; the difference is that no delivery accounts for it. Letting the
    /// verb through here would re-mint rot into the manifest under a friendlier
    /// name than `rebaseline`.
    @Test func refusesDamageThatNoDeliveryAccountsFor() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let ada = try archive.addPerson(.sample(given: "Ada", surname: "Rot")).uid
        let file = root.appendingPathComponent(path(of: ada))
        try Data("{\"uid\":\"corrupted\"}".utf8).write(to: file)

        #expect(!archive.deliveryIsInFlight, "nothing is arriving; this is damage")
        #expect(
            throws: ArchiveError.notAwaitingDelivery(
                path: path(of: ada), reason: .notADelivery)
        ) {
            try archive.abandonDelivery(path: self.path(of: ada))
        }
        // And the damage is still reported afterwards — the refusal changed
        // nothing.
        #expect(try !archive.verifyIntegrity().isClean)
    }

    /// Convergence, 50 fork (d)'s shape: the second call has nothing to do and
    /// says so rather than writing again.
    @Test func abandoningTwiceIsRefusedTheSecondTime() throws {
        let staged = try stageDeliveryOfAnEditThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        let awaited = path(of: staged.awaited)
        try archive.abandonDelivery(path: awaited)

        #expect(
            throws: ArchiveError.notAwaitingDelivery(
                path: awaited, reason: .fileMatches)
        ) {
            try archive.abandonDelivery(path: awaited)
        }
    }

    // MARK: - What `/code-review` found the gate was missing

    /// **A payload path is refused, because dropping its entry does nothing.**
    /// `payloadEntries` re-derives every attached file's entry from the
    /// `record.json` that claims it, so the closing recompute puts the entry
    /// straight back. Before the guard the call *also* wrote its note, leaving
    /// `verify` reporting one path as both awaited and abandoned for ever and
    /// accepting the request again every time.
    @Test func refusesAnArtifactPayloadPath() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let artifact = try otherArchive.addArtifact(.sample())
        _ = try otherArchive.attachFile(
            copyingFrom: try TestSupport.makeSourceFile(contents: "master scan"),
            to: artifact.uid, role: .preservationMaster)

        let mine = try clone(other)
        _ = try otherArchive.attachFile(
            copyingFrom: try TestSupport.makeSourceFile(named: "second.txt", contents: "later"),
            to: artifact.uid, role: .preservationMaster)
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)

        let archive = try Archive.open(at: mine)
        let payload = try #require(
            try archive.verifyIntegrity().issues.compactMap { issue -> String? in
                guard case .awaitingDelivery(let p) = issue,
                    !ArchiveLayout.isEngineAuthored(relativePath: p)
                else { return nil }
                return p
            }.first)

        #expect(
            throws: ArchiveError.notAwaitingDelivery(
                path: payload, reason: .notManifestAuthored)
        ) {
            try archive.abandonDelivery(path: payload)
        }
        // And nothing was recorded — the contradiction was the worst half.
        #expect(try archive.verifyIntegrity().abandonedPaths.isEmpty)
    }

    /// **An interrupted write is refused, because `verifyIntegrity()` classifies
    /// it ahead of an arrival.** The local bytes may be half a commit of ours
    /// rather than a good older version of theirs, so blessing them is
    /// `rebaseline()`'s decision and its warning.
    @Test func refusesWhenAWriteOfOursDidNotFinish() throws {
        let staged = try stageDeliveryOfAnEditThatNeverLands()
        let awaited = path(of: staged.awaited)
        // A write of ours to the same record got as far as its sidecar. The
        // marker alone would settle on open (slice 65): bytes unchanged since the
        // last settling are an arrival still on its way, not a write that died.
        let record = staged.mine.appendingPathComponent(awaited)
        try (Data(contentsOf: record) + Data("\n".utf8)).write(to: record)
        try IndexDirtyMarker.set(in: staged.mine)

        let archive = try Archive.open(at: staged.mine)
        #expect(
            throws: ArchiveError.notAwaitingDelivery(
                path: awaited, reason: .interruptedWrite)
        ) {
            try archive.abandonDelivery(path: awaited)
        }
    }

    /// **A note that has stopped standing is deleted, not merely filtered.** A
    /// dropped-entry note records the empty string, so it stops standing when
    /// the version lands — and would stand *again*, permanently, the moment
    /// anything removed that entry later. Filtering alone let a deletion the
    /// user made resurrect a decision they had made about something else.
    @Test func aNoteFalsifiedByAnArrivalDoesNotComeBack() throws {
        let staged = try stageDeliveryOfACreationThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        let awaited = path(of: staged.awaited)
        try archive.abandonDelivery(path: awaited)
        #expect(try archive.verifyIntegrity().abandonedPaths == [awaited])

        // The creation lands after all, the way one does.
        try TestSupport.deliver(["manifest.json", awaited], from: staged.other, to: staged.mine)
        try archive.reconcileIfStale()
        #expect(try archive.verifyIntegrity().abandonedPaths.isEmpty)

        // …and the user then deletes that record, which takes the entry back out
        // of the manifest — the exact shape the note would have re-matched.
        _ = try archive.removePerson(staged.awaited)
        #expect(
            try archive.verifyIntegrity().abandonedPaths.isEmpty,
            "a stale note must be gone, not waiting for its shape to recur")
    }

    // MARK: - Fork (c) — the note

    @Test func theAbandonmentIsRecordedAsANoteNotAFinding() throws {
        let staged = try stageDeliveryOfAnEditThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        let awaited = path(of: staged.awaited)
        try archive.abandonDelivery(path: awaited)

        let report = try archive.verifyIntegrity()
        #expect(report.abandonedPaths == [awaited])
        #expect(report.isClean, "a decision the user made is not a problem with the archive")
        #expect(report.issues.isEmpty)
    }

    /// The note clears itself once the entry it explains has moved on — here by
    /// a local edit, which is the cheaper half of the same rule that clears it
    /// when the version lands after all.
    @Test func theNoteClearsWhenTheEntryMovesAgain() throws {
        let staged = try stageDeliveryOfAnEditThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        try archive.abandonDelivery(path: path(of: staged.awaited))
        #expect(try archive.verifyIntegrity().abandonedPaths == [path(of: staged.awaited)])

        try addName("MY-LATER-EDIT", to: staged.awaited, in: archive)

        #expect(try archive.verifyIntegrity().abandonedPaths.isEmpty)
    }

    // MARK: - Recoverability — what makes this offerable where `rebaseline` is not

    /// **The version lands after all.** Nothing was deleted, so the file that
    /// turns up later is walked into the index by the next rebuild and re-minted
    /// by the next mutation, with the archive clean throughout.
    @Test func aVersionThatLandsAfterAnAbandonmentIsStillTakenUp() throws {
        let staged = try stageDeliveryOfAnEditThatNeverLands()
        let archive = try Archive.open(at: staged.mine)
        let awaited = path(of: staged.awaited)
        try archive.abandonDelivery(path: awaited)
        #expect(try archive.verifyIntegrity().isClean)

        // **The straggler finally crosses — the way one actually does**, with the
        // manifest that names it. (A record arriving *alone* is an out-of-band
        // edit, which slice 49 deliberately reports rather than adopts; that is
        // not this slice's case and abandoning does not change it.)
        try TestSupport.deliver(["manifest.json", awaited], from: staged.other, to: staged.mine)
        try archive.reconcileIfStale()

        let person = try #require(try archive.person(withID: staged.awaited))
        #expect(
            person.names.contains { $0.surname == "OTHER-EDIT" },
            "the abandoned version is adopted normally when it turns up")
        #expect(try archive.verifyIntegrity().isClean)
        let entry = try #require(try manifest(at: staged.mine).files.first { $0.path == awaited })
        let onDisk = try Checksum.sha256Hex(
            ofFileAt: staged.mine.appendingPathComponent(awaited))
        #expect(entry.sha256 == onDisk)
        #expect(
            try archive.verifyIntegrity().abandonedPaths.isEmpty,
            "the note stops meaning anything once the entry has moved")
    }
}
