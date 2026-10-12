import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 58b — a new artifact must not take an unreadable record's folder.
///
/// `addArtifact` and `restoreFromTrash` made a slug unique against the index
/// alone, and a folder whose `record.json` the walk could not read has no row. So
/// a new artifact titled like the damaged one was given its folder: refused by
/// 58's drift guard (an unrelated add failing over a name), or — where the guard
/// stands down — written over it, after which the next rebuild displaced the old
/// record's preserved copy with the new record's row.
@Suite struct UnreadableFolderSlugTests {

    private func makeArchive() throws -> (Archive, URL) {
        let root = TestSupport.makeTempDirectory()
        return (try Archive.create(at: root), root)
    }

    private func slug(of id: ArtifactID, in archive: Archive) throws -> String {
        try #require(archive.artifacts().first { $0.uid == id }?.slug)
    }

    private func recordURL(_ slug: String, in root: URL) -> URL {
        ArchiveLayout.recordURL(in: root, slug: slug)
    }

    private func recordPath(_ slug: String) -> String {
        "artifacts/\(slug)/record.json"
    }

    // MARK: - addArtifact

    /// The review's scenario, either side of *Accept Current Contents*: the add
    /// lands in a folder of its own, the damaged bytes are untouched, the copy
    /// survives the rebuild that used to displace it, and the repair still puts
    /// the old record back exactly.
    @Test(arguments: [false, true])
    func anAddDoesNotTakeADamagedRecordsFolder(rebaselineFirst: Bool) throws {
        let (archive, root) = try makeArchive()
        let damaged = try archive.addArtifact(.sample(title: "Census"))
        let damagedSlug = try slug(of: damaged.uid, in: archive)
        let original = try Data(contentsOf: recordURL(damagedSlug, in: root))
        let junk = Data("{ not JSON".utf8)
        try junk.write(to: recordURL(damagedSlug, in: root))
        try archive.rebuildIndex()
        if rebaselineFirst { try archive.rebaseline() }

        let added = try archive.addArtifact(.sample(title: "Census"))

        #expect(try slug(of: added.uid, in: archive) != damagedSlug)
        #expect(try Data(contentsOf: recordURL(damagedSlug, in: root)) == junk)
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths() == [recordPath(damagedSlug)])

        try archive.repairRecord(atPath: recordPath(damagedSlug))
        #expect(try Data(contentsOf: recordURL(damagedSlug, in: root)) == original)
        #expect(Set(archive.artifacts().map(\.uid)) == [damaged.uid, added.uid])
    }

    /// Where the overwrite was really reachable: `rebaseline()` blesses a
    /// straggler's bytes (it reads; only its format is older), after which the
    /// drift guard has nothing to object to — and the straggler is the one
    /// version of that record an upgrade could migrate.
    @Test func anAddDoesNotOverwriteABlessedStraggler() throws {
        let (archive, root) = try makeArchive()
        let straggler = try archive.addArtifact(.sample(title: "Census"))
        let stragglerSlug = try slug(of: straggler.uid, in: archive)
        let url = recordURL(stragglerSlug, in: root)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["schemaVersion"] = "0.9"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        let doctored = try Data(contentsOf: url)
        try archive.rebuildIndex()
        try archive.rebaseline()

        let added = try archive.addArtifact(.sample(title: "Census"))

        #expect(try slug(of: added.uid, in: archive) != stragglerSlug)
        #expect(try Data(contentsOf: url) == doctored)
    }

    /// A sidecar that *vanished* keeps its copy and its repair offer, and the
    /// repair writes back to the old path — so that path stays taken after the
    /// folder is gone. Otherwise the repair would carry the new, healthy record
    /// off to `.damaged/`.
    @Test func anAddDoesNotTakeTheFolderOfARecordThatVanished() throws {
        let (archive, root) = try makeArchive()
        let vanished = try archive.addArtifact(.sample(title: "Census"))
        let vanishedSlug = try slug(of: vanished.uid, in: archive)
        let original = try Data(contentsOf: recordURL(vanishedSlug, in: root))
        try FileManager.default.removeItem(
            at: ArchiveLayout.artifactDirectory(in: root, slug: vanishedSlug))
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths() == [recordPath(vanishedSlug)])

        let added = try archive.addArtifact(.sample(title: "Census"))
        let addedSlug = try slug(of: added.uid, in: archive)
        #expect(addedSlug != vanishedSlug)
        let addedBytes = try Data(contentsOf: recordURL(addedSlug, in: root))

        let outcome = try archive.repairRecord(atPath: recordPath(vanishedSlug))
        #expect(outcome.quarantinedPath == nil)
        #expect(try Data(contentsOf: recordURL(vanishedSlug, in: root)) == original)
        #expect(try Data(contentsOf: recordURL(addedSlug, in: root)) == addedBytes)
        #expect(Set(archive.artifacts().map(\.uid)) == [vanished.uid, added.uid])
    }

    /// A folder with no `record.json` at all — a stray, or one whose sidecar went
    /// before anything indexed it — is somebody's, and a new artifact's files do
    /// not belong in it.
    @Test func anAddDoesNotMoveIntoAStrayFolder() throws {
        let (archive, root) = try makeArchive()
        let stray = ArchiveLayout.artifactDirectory(in: root, slug: "census")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("scan".utf8).write(to: stray.appendingPathComponent("scan.jpg"))

        let added = try archive.addArtifact(.sample(title: "Census"))

        #expect(try slug(of: added.uid, in: archive) != "census")
        #expect(try FileManager.default.contentsOfDirectory(atPath: stray.path) == ["scan.jpg"])
    }

    /// A delivery can bring the manifest before the folder it describes. The
    /// folder still in flight is in neither the index nor on disk, so only the
    /// manifest says the name is spoken for (`/code-review`).
    @Test func anAddDoesNotTakeTheFolderOfARecordStillArriving() throws {
        let (_, mine) = try makeArchive()
        let other = TestSupport.makeTempDirectory().appendingPathComponent("other.genea")
        try FileManager.default.copyItem(at: mine, to: other)
        let theirs = try Archive.open(at: other).addArtifact(.sample(title: "Census"))
        let theirSlug = try slug(of: theirs.uid, in: Archive.open(at: other))
        try FileManager.default.removeItem(at: ArchiveLayout.manifestURL(in: mine))
        try FileManager.default.copyItem(
            at: ArchiveLayout.manifestURL(in: other), to: ArchiveLayout.manifestURL(in: mine))

        let archive = try Archive.open(at: mine)
        let added = try archive.addArtifact(.sample(title: "Census"))

        #expect(try slug(of: added.uid, in: archive) != theirSlug)
    }

    /// `fileExists` follows a link, so a dangling one read as free and the write
    /// into it failed (`/code-review`).
    @Test func anAddDoesNotTakeADanglingLink() throws {
        let (archive, root) = try makeArchive()
        try FileManager.default.createDirectory(
            at: ArchiveLayout.artifactsDirectory(in: root), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: ArchiveLayout.artifactDirectory(in: root, slug: "census").path,
            withDestinationPath: root.appendingPathComponent("nowhere").path)

        let added = try archive.addArtifact(.sample(title: "Census"))

        #expect(try slug(of: added.uid, in: archive) != "census")
    }

    /// Only "no such file" is free. A probe the file system refuses is an error,
    /// not an answer: read as *free* the add wrote blind, and read as *occupied*
    /// every attempt would be refused alike and the search would never end
    /// (`/code-review`).
    @Test func anAddThrowsWhenTheDiskCannotSay() throws {
        guard getuid() != 0 else { return }  // root reads through any mode
        let (archive, root) = try makeArchive()
        let artifacts = ArchiveLayout.artifactsDirectory(in: root)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: artifacts.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: artifacts.path)
        }

        #expect(throws: POSIXError.self) { try archive.addArtifact(.sample(title: "Census")) }
    }

    @Test func anArtifactRecordPathParsesAsRepairAlwaysParsedIt() {
        #expect(ArchiveLayout.artifactSlug(ofRecordPath: "artifacts/census/record.json") == "census")
        #expect(ArchiveLayout.artifactSlug(ofRecordPath: "artifacts//census/record.json") == "census")
        #expect(ArchiveLayout.artifactSlug(ofRecordPath: "artifacts/census/scan.jpg") == nil)
        #expect(ArchiveLayout.artifactSlug(ofRecordPath: "artifacts/a/b/record.json") == nil)
        #expect(ArchiveLayout.artifactSlug(ofRecordPath: "conclusions/persons/record.json") == nil)
    }

    // MARK: - restoreFromTrash

    /// The original slug is now an unreadable record's folder: the restore takes
    /// a fresh one rather than failing its move — or landing on the damaged file.
    @Test func aRestoreDoesNotTakeADamagedRecordsFolder() throws {
        let (archive, root) = try makeArchive()
        let trashed = try archive.addArtifact(.sample(title: "Census"))
        let originalSlug = try slug(of: trashed.uid, in: archive)
        try archive.removeArtifact(trashed.uid)
        let occupant = try archive.addArtifact(.sample(title: "Census"))
        #expect(try slug(of: occupant.uid, in: archive) == originalSlug)
        let junk = Data("{ not JSON".utf8)
        try junk.write(to: recordURL(originalSlug, in: root))
        try archive.rebuildIndex()

        try archive.restoreFromTrash(trashed.uid)

        #expect(try slug(of: trashed.uid, in: archive) != originalSlug)
        #expect(try Data(contentsOf: recordURL(originalSlug, in: root)) == junk)
        #expect(try archive.preservedRecordPaths() == [recordPath(originalSlug)])
    }

    /// The one copy that does not take a slug: the restored record's own. A
    /// deletion that arrives by sync leaves exactly that — the folder gone, the
    /// copy kept — and the restore is the record coming back to its own folder.
    @Test func aRestoreRegainsItsSlugOverItsOwnPreservedCopy() throws {
        let (archive, root) = try makeArchive()
        let trashed = try archive.addArtifact(.sample(title: "Census"))
        let originalSlug = try slug(of: trashed.uid, in: archive)
        try FileManager.default.copyItem(
            at: ArchiveLayout.artifactDirectory(in: root, slug: originalSlug),
            to: root.appendingPathComponent("held"))
        try archive.removeArtifact(trashed.uid)
        // The folder back, the index told nothing, then gone again: the shape a
        // deletion delivered from another machine leaves.
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("held"),
            to: ArchiveLayout.artifactDirectory(in: root, slug: originalSlug))
        try archive.rebuildIndex()
        try FileManager.default.removeItem(
            at: ArchiveLayout.artifactDirectory(in: root, slug: originalSlug))
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths() == [recordPath(originalSlug)])

        try archive.restoreFromTrash(trashed.uid)

        #expect(try slug(of: trashed.uid, in: archive) == originalSlug)
        // Gone with the restore, not at the next rebuild: a repair offered on it
        // would carry the restored record off to `.damaged/` (`/code-review`).
        #expect(try archive.preservedRecordPaths().isEmpty)
        #expect(try archive.repairPlan(forRecordAt: recordPath(originalSlug)) == nil)
    }

    /// A deletion delivered while this machine's session is open: the folder is
    /// gone and the trash entry has arrived, but this machine's index row and
    /// manifest entry still name the record. Both are the record's *own* — the
    /// row by uid, the entry by checksum — so neither keeps it from its folder
    /// (`/code-review`); taking `letter-2` strands it when the other machine's
    /// restored folder lands under the old name.
    @Test func aRestoreRegainsItsSlugWhenItsDeletionHasJustArrived() throws {
        let (_, mine) = try makeArchive()
        let letter = try Archive.open(at: mine).addArtifact(.sample(title: "Letter"))
        let other = TestSupport.makeTempDirectory().appendingPathComponent("other.genea")
        try FileManager.default.copyItem(at: mine, to: other)
        let archive = try Archive.open(at: mine)
        let originalSlug = try slug(of: letter.uid, in: archive)
        _ = try Archive.open(at: other).removeArtifact(letter.uid)

        try FileManager.default.removeItem(
            at: ArchiveLayout.artifactDirectory(in: mine, slug: originalSlug))
        let trash = mine.appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: other.appendingPathComponent(".trash/\(letter.uid.raw)"),
            to: trash.appendingPathComponent(letter.uid.raw))
        let manifest = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: mine)))
        #expect(manifest.files.contains { $0.path == recordPath(originalSlug) })

        try archive.restoreFromTrash(letter.uid)

        #expect(try slug(of: letter.uid, in: archive) == originalSlug)
    }

    /// A restore that has to re-slug — its old folder is occupied — still drops
    /// its copy at the old path: the record is live again, and a repair of that
    /// path would write a second folder claiming its uid (`/code-review`).
    @Test func aRestoreElsewhereStillDropsItsPreservedCopy() throws {
        let (archive, root) = try makeArchive()
        let trashed = try archive.addArtifact(.sample(title: "Census"))
        let originalSlug = try slug(of: trashed.uid, in: archive)
        let folder = ArchiveLayout.artifactDirectory(in: root, slug: originalSlug)
        try FileManager.default.copyItem(at: folder, to: root.appendingPathComponent("held"))
        try archive.removeArtifact(trashed.uid)
        try FileManager.default.moveItem(at: root.appendingPathComponent("held"), to: folder)
        try archive.rebuildIndex()
        try FileManager.default.removeItem(at: folder)
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths() == [recordPath(originalSlug)])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("scan".utf8).write(to: folder.appendingPathComponent("scan.jpg"))

        try archive.restoreFromTrash(trashed.uid)

        #expect(try slug(of: trashed.uid, in: archive) != originalSlug)
        #expect(try archive.preservedRecordPaths().isEmpty)
        #expect(try archive.repairPlan(forRecordAt: recordPath(originalSlug)) == nil)
    }

    /// A folder differing only in case. On a case-insensitive volume it *is* the
    /// original folder, and the move used to refuse over it; the disk is probed
    /// rather than listed (58b), so there the file system's folding finds it, and
    /// on a case-sensitive one the two folders simply coexist. Either way the
    /// restore lands, and the stray is left as it was.
    @Test func aRestoreDoesNotLandInACaseVariantFolder() throws {
        let (archive, root) = try makeArchive()
        let trashed = try archive.addArtifact(.sample(title: "Census"))
        let originalSlug = try slug(of: trashed.uid, in: archive)
        try archive.removeArtifact(trashed.uid)
        let stray = ArchiveLayout.artifactDirectory(in: root, slug: originalSlug.uppercased())
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("scan".utf8).write(to: stray.appendingPathComponent("scan.jpg"))

        try archive.restoreFromTrash(trashed.uid)

        let restored = try slug(of: trashed.uid, in: archive)
        #expect(FileManager.default.fileExists(atPath: recordURL(restored, in: root).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: stray.path) == ["scan.jpg"])
    }
}
