import Foundation
import GeneaLogicModel
import Synchronization
import Testing

@testable import GeneaLogicArchive

/// The shapes `WriteCutTests` finds, each built by hand and named — slice 65's
/// forks (c), (e) and (f), plus the seam the property stands on.
@Suite struct CrashResidueTests {

    private func marker(in root: URL) -> URL {
        root.appendingPathComponent(".index/\(MachineKey.current)/dirty")
    }

    private func suspectMarker(in root: URL) -> URL {
        root.appendingPathComponent(".index/\(MachineKey.current)/interrupted")
    }

    private func archiveWithAFile() throws -> (Archive, URL, Artifact, FileEntry) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Census"))
        let attached = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "recto"),
            to: artifact.uid, role: .preservationMaster)
        return (archive, root, artifact, attached.entry)
    }

    private func slug(of artifact: Artifact, in archive: Archive) throws -> String {
        try #require(archive.artifacts().first { $0.uid == artifact.uid }?.slug)
    }

    // MARK: - Fork (f): the flag is settled on open

    /// A crash that diverged nothing — between `dirty` and the first write, or
    /// between the manifest commit and the clear — no longer leaves the archive
    /// suspect, and the marker goes with the flag.
    @Test func aMarkerWithNothingBehindItSettlesOnOpen() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root).addPerson(.sample())
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        #expect(!reopened.interruptedWriteSuspected)
        #expect(!FileManager.default.fileExists(atPath: marker(in: root).path))
        #expect(try reopened.verifyIntegrity().isClean)
    }

    /// A crash that did leave the manifest behind stays suspect — **across a
    /// second open**, which used to lose the flag and call the half-written record
    /// corrupt — until `rebaseline()` resolves it and takes the marker away. The
    /// recovery itself runs once: the first open records its verdict and clears
    /// `dirty`, so the second neither rebuilds nor re-hashes (`/code-review`, 65).
    @Test func aRealDivergenceSurvivesASecondOpenUntilRebaselined() throws {
        let root = TestSupport.makeTempDirectory()
        let person = try Archive.create(at: root).addPerson(.sample())
        let path = "conclusions/persons/\(person.uid.raw).json"
        let record = root.appendingPathComponent(path)
        try (Data(contentsOf: record) + Data("\n".utf8)).write(to: record)
        try IndexDirtyMarker.set(in: root)

        let first = try Archive.open(at: root)
        #expect(first.interruptedWriteSuspected)
        #expect(try first.verifyIntegrity().issues == [.interruptedWrite(path: path)])
        #expect(!FileManager.default.fileExists(atPath: marker(in: root).path))
        #expect(FileManager.default.fileExists(atPath: suspectMarker(in: root).path))

        // Proof the second open did not rebuild: a record removed behind the
        // index's back is still served from it.
        let other = try first.addPerson(.sample(given: "Bystander"))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("conclusions/persons/\(other.uid.raw).json"))
        let second = try Archive.open(at: root)
        #expect(second.interruptedWriteSuspected)
        #expect(second.person(withID: other.uid) != nil)
        #expect(try second.verifyIntegrity().issues.contains(.interruptedWrite(path: path)))

        try second.rebaseline()
        #expect(!second.interruptedWriteSuspected)
        #expect(!FileManager.default.fileExists(atPath: marker(in: root).path))
        #expect(!FileManager.default.fileExists(atPath: suspectMarker(in: root).path))
        #expect(!(try Archive.open(at: root)).interruptedWriteSuspected)
    }

    /// An ordinary mutation on a suspect archive does not clear the marker — only
    /// `rebaseline()` resolves what it stands for (47's rule, kept).
    @Test func anOrdinaryMutationLeavesAnUnresolvedMarker() throws {
        let root = TestSupport.makeTempDirectory()
        let person = try Archive.create(at: root).addPerson(.sample())
        let record = root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json")
        try (Data(contentsOf: record) + Data("\n".utf8)).write(to: record)
        try IndexDirtyMarker.set(in: root)

        let archive = try Archive.open(at: root)
        _ = try archive.addPerson(.sample(given: "Another"))
        #expect(FileManager.default.fileExists(atPath: suspectMarker(in: root).path))
        #expect(try Archive.open(at: root).interruptedWriteSuspected)
    }

    // MARK: - Fork (c): two more shapes the sentinel explains

    /// The archive a crash leaves at the first checkpoint `matching` accepts
    /// while `mutate` runs — the shape built by the engine itself, not by hand.
    private func crashImage(
        of root: URL, at matching: @escaping @Sendable (String, URL) -> Bool,
        during mutate: () throws -> Void
    ) throws -> URL {
        let image = TestSupport.makeTempDirectory().appendingPathComponent("image.genea")
        let taken = Mutex(false)
        WriteCheckpoint.install(root: root) { event, url in
            taken.withLock { taken in
                guard !taken, matching(event, url) else { return }
                taken = (try? FileManager.default.copyItem(at: root, to: image)) != nil
            }
        }
        defer { WriteCheckpoint.remove(root: root) }
        try mutate()
        #expect(taken.withLock { $0 }, "no checkpoint matched")
        return image
    }

    /// A manifest entry whose file is gone and which nothing the archive holds
    /// still names is a removal whose manifest never caught up — not a missing
    /// file. One the archive still claims stays `.missingFile`.
    @Test func anUnreferencedMissingEntryIsAnInterruptedWrite() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        let notes = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "notes.txt", contents: "transcribed"),
            to: artifact.uid, role: .transcript)
        let directory = "artifacts/\(try slug(of: artifact, in: archive))"
        // A detach cut after its record was rewritten and before its manifest:
        // the manifest still lists the path, the bytes are in the trash.
        let image = try crashImage(
            of: root, at: { event, url in event == "renamed" && url.lastPathComponent == "record.json" }
        ) { _ = try archive.detachFile(entry.uid, in: artifact.uid) }
        // And a payload the record still claims, really missing.
        try FileManager.default.removeItem(
            at: image.appendingPathComponent("\(directory)/\(notes.entry.path)"))

        let issues = try Archive.open(at: image).verifyIntegrity().issues
        #expect(issues.contains(.interruptedWrite(path: "\(directory)/\(entry.path)")))
        #expect(issues.contains(.missingFile(path: "\(directory)/\(notes.entry.path)")))
    }

    /// A payload whose sidecar already records the bytes on disk is a manifest
    /// that fell behind; one whose sidecar disagrees too is damage, sentinel or
    /// no sentinel.
    @Test func aPayloadTheSidecarAlreadyDescribesIsAnInterruptedWrite() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        let path = "artifacts/\(try slug(of: artifact, in: archive))/\(entry.path)"
        let manifestURL = ArchiveLayout.manifestURL(in: root)
        var manifest = try Archive.readManifest(at: manifestURL)
        let index = try #require(manifest.files.firstIndex { $0.path == path })
        manifest.files[index].sha256 = String(repeating: "0", count: 64)
        try AtomicIO.writeJSON(manifest, to: manifestURL)
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        #expect(try reopened.verifyIntegrity().issues == [.interruptedWrite(path: path)])

        // Rot under the same flag: the bytes now match neither.
        try Data("rotted".utf8).write(to: root.appendingPathComponent(path))
        #expect(
            try reopened.verifyIntegrity().issues.contains {
                if case .checksumMismatch(path, _, _) = $0 { return true }
                return false
            })
    }

    // MARK: - Fork (e): the trash, reconciled after a crash

    /// A detach that died after moving the bytes and before rewriting the record:
    /// the record is the arbiter, so the bytes go back and the entry goes.
    @Test func aTornDetachIsPutBack() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        let fileURL = root.appendingPathComponent(
            "artifacts/\(try slug(of: artifact, in: archive))/\(entry.path)")
        try TrashStore.stash(
            item: fileURL, uid: entry.uid.raw,
            entry: TrashEntry(
                kind: .file, deletedAt: "2026-10-01T00:00:00Z",
                file: FileTrashInfo(
                    entry: entry, artifactUID: artifact.uid, artifactTitle: "Census")),
            in: root)
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        #expect(try Data(contentsOf: fileURL) == Data("recto".utf8))
        #expect(reopened.trashedFiles().isEmpty)
        #expect(try reopened.verifyIntegrity().isClean)
        #expect(!reopened.interruptedWriteSuspected)
    }

    /// A stash that died before its move leaves a listed entry with no payload
    /// beside a live artifact; it is dropped, never shown as restorable.
    @Test func aTornStashIsDropped() throws {
        let (archive, root, artifact, _) = try archiveWithAFile()
        let trashed = TrashEntry(
            kind: .artifact, deletedAt: "2026-10-01T00:00:00Z",
            artifact: ArtifactTrashInfo(
                uid: artifact.uid, title: artifact.title,
                originalSlug: try slug(of: artifact, in: archive)))
        try AtomicIO.writeJSON(
            trashed, to: ArchiveLayout.trashRecordURL(in: root, uid: artifact.uid.raw))
        // And an entry folder a stash created and wrote nothing into.
        try FileManager.default.createDirectory(
            at: ArchiveLayout.trashEntryDirectory(in: root, uid: "FIL-empty"),
            withIntermediateDirectories: true)
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.trashedArtifacts().isEmpty)
        #expect(reopened.artifact(withID: artifact.uid) != nil)
        #expect(
            (try FileManager.default.contentsOfDirectory(
                atPath: ArchiveLayout.trashDirectory(in: root).path)).isEmpty)
    }

    /// **Only after a crash of ours.** Without the sentinel the same shape could
    /// be a sync delivery that brought `.trash/` ahead of the record that moved on,
    /// and putting bytes back would strand them; the open leaves it alone.
    @Test func withoutTheSentinelTheTrashIsLeftAlone() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        let fileURL = root.appendingPathComponent(
            "artifacts/\(try slug(of: artifact, in: archive))/\(entry.path)")
        try TrashStore.stash(
            item: fileURL, uid: entry.uid.raw,
            entry: TrashEntry(
                kind: .file, deletedAt: "2026-10-01T00:00:00Z",
                file: FileTrashInfo(
                    entry: entry, artifactUID: artifact.uid, artifactTitle: "Census")),
            in: root)

        let reopened = try Archive.open(at: root)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(reopened.trashedFiles().count == 1)
    }

    /// A purge cut anywhere leaves the entry listed whole or gone whole: one rename
    /// takes it out of the listing, and the open after the crash finishes the
    /// delete. Payload-first left a `.file` entry with nothing to restore, which
    /// read as a legitimate record-only one (`/code-review`, 65).
    @Test func aPurgeCutInHalfLeavesNoHollowEntry() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        _ = try archive.detachFile(entry.uid, in: artifact.uid)
        let image = try crashImage(
            of: root, at: { event, url in event == "moved" && url.lastPathComponent.hasPrefix(".") }
        ) { try archive.deleteFileFromTrash(entry.uid) }

        let reopened = try Archive.open(at: image)
        #expect(reopened.trashedFiles().isEmpty)
        #expect(try reopened.verifyIntegrity().isClean)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: ArchiveLayout.trashDirectory(in: image).path
            ).isEmpty)
    }

    /// A stash whose move fails takes its `deletion.json` back out: nothing else
    /// would, and the trash would list a subject that is still live
    /// (`/code-review`, 65).
    @Test func aStashWhoseMoveFailsLeavesNoEntry() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root)
        let entry = TrashEntry(
            kind: .artifact, deletedAt: "2026-10-01T00:00:00Z",
            artifact: ArtifactTrashInfo(uid: ArtifactID("ART-x"), title: "x", originalSlug: "x"))
        #expect(throws: (any Error).self) {
            try TrashStore.stash(
                item: root.appendingPathComponent("artifacts/not-there"), uid: "ART-x",
                entry: entry, in: root)
        }
        #expect(TrashStore.entries(in: root).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: ArchiveLayout.trashEntryDirectory(in: root, uid: "ART-x").path))
    }

    /// `restoreFile` writes the record before the move, so it picks a name free
    /// on disk too: a stray at the old name — what a cut attach or replace leaves
    /// — must not be claimed by the record (`/code-review`, 65).
    @Test func aRestoreSidestepsAStrayAtItsOldName() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        let directory = root.appendingPathComponent(
            "artifacts/\(try slug(of: artifact, in: archive))")
        _ = try archive.detachFile(entry.uid, in: artifact.uid)
        try Data("stray".utf8).write(to: directory.appendingPathComponent(entry.path))

        let restored = try archive.restoreFile(entry.uid)
        #expect(restored.path != entry.path)
        #expect(
            try Data(contentsOf: directory.appendingPathComponent(restored.path))
                == Data("recto".utf8))
        #expect(archive.trashedFiles().isEmpty)
        let slug = try slug(of: artifact, in: archive)
        #expect(
            try archive.verifyIntegrity().issues == [
                .unreferencedFile(path: "artifacts/\(slug)/\(entry.path)")
            ])
    }

    /// **A detach from another machine is not a torn one of ours.** Its trash entry
    /// and manifest can land before its record does; with a crash marker of our
    /// own lying about, the reconcile must leave it alone rather than put the bytes
    /// back and purge the other machine's entry (`/code-review`, 65).
    @Test func theReconcileLeavesADeliveredDetachAlone() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        // A second file, so the other machine's record after its detach is not
        // byte-identical to one this machine superseded — which 50's merge would
        // read as a stale manifest and keep ours (a separate, pre-existing ABA).
        _ = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "notes.txt", contents: "transcribed"),
            to: artifact.uid, role: .transcript)
        let slug = try slug(of: artifact, in: archive)
        let other = TestSupport.makeTempDirectory().appendingPathComponent("other.genea")
        try FileManager.default.copyItem(at: root, to: other)
        _ = try Archive.open(at: other).detachFile(entry.uid, in: artifact.uid)

        // The trash entry, the manifest and the file's removal arrive; the record
        // has not yet, so here it still claims the file.
        let trashed = ".trash/\(entry.uid.raw)"
        try FileManager.default.createDirectory(
            at: ArchiveLayout.trashDirectory(in: root), withIntermediateDirectories: true)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("artifacts/\(slug)/\(entry.path)"))
        try FileManager.default.copyItem(
            at: other.appendingPathComponent(trashed), to: root.appendingPathComponent(trashed))
        try FileManager.default.removeItem(at: ArchiveLayout.manifestURL(in: root))
        try FileManager.default.copyItem(
            at: ArchiveLayout.manifestURL(in: other), to: ArchiveLayout.manifestURL(in: root))
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.trashedFiles().map(\.uid) == [entry.uid])
        #expect(
            FileManager.default.fileExists(
                atPath: TrashStore.payloadURL(uid: entry.uid.raw, in: root).path))
        // The bytes were not moved back to the path the stale record names.
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("artifacts/\(slug)/\(entry.path)").path))
    }

    // MARK: - The seam

    /// Every write primitive reports itself, or a cut there is one the property
    /// cannot see.
    @Test func everyWritePrimitiveReachesACheckpoint() throws {
        let (archive, root, artifact, entry) = try archiveWithAFile()
        let seen = Mutex<Set<String>>([])
        WriteCheckpoint.install(root: root) { event, _ in seen.withLock { _ = $0.insert(event) } }
        defer { WriteCheckpoint.remove(root: root) }

        _ = try archive.replaceFile(
            entry.uid, in: artifact.uid,
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "verso"))
        let replaced = try #require(archive.artifact(withID: artifact.uid)?.files.first)
        _ = try archive.detachFile(replaced.uid, in: artifact.uid)
        _ = try archive.restoreFile(replaced.uid)
        _ = try archive.removeArtifact(artifact.uid)

        #expect(
            seen.withLock { $0 }.isSuperset(of: [
                "marker set", "temp written", "renamed", "sql step", "sql exec", "moved",
                "unlinked", "created", "before marker clear",
            ]))
    }

    /// Hooks are scoped to the archive they were installed for: tests run in
    /// parallel, and one archive's cuts must not photograph another's.
    @Test func aHookSeesOnlyItsOwnArchive() throws {
        let watched = TestSupport.makeTempDirectory()
        let other = try Archive.create(at: TestSupport.makeTempDirectory())
        let count = Mutex(0)
        WriteCheckpoint.install(root: watched) { _, _ in count.withLock { $0 += 1 } }
        defer { WriteCheckpoint.remove(root: watched) }

        _ = try other.addPerson(.sample())
        #expect(count.withLock { $0 } == 0)
    }
}
