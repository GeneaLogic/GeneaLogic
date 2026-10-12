import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 56 — the findings a host can afford to read on every open.
///
/// `verifyIntegrity()` hashes every tracked file; `standingFindings()` reads what
/// `.index/` already recorded. The line between them is the whole point of the
/// call, so it is what these tests hold.
@Suite struct StandingFindingsTests {

    @Test func aCleanArchiveHasNothingStanding() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample())

        #expect(try archive.standingFindings().isEmpty)
    }

    @Test func anUnreadableRecordIsStanding() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        try Data("not JSON".utf8).write(
            to: root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json"))
        try archive.rebuildIndex()

        let findings = try archive.standingFindings()
        #expect(findings.unreadableRecords == ["conclusions/persons/\(person.uid.raw).json"])
        #expect(!findings.isEmpty)
    }

    /// The free/expensive line, stated as a test because it is exactly what a
    /// later refactor would blur: rot in a tracked file is *not* standing, and
    /// must not be — finding it costs a full hash, which is what
    /// `verifyIntegrity()` is for.
    @Test func rotInATrackedFileIsNotStanding() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample())
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "original")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)

        try Data("ROTTED".utf8).write(
            to: root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)"))

        #expect(try archive.standingFindings().isEmpty)
        // …and the expensive call still sees it, so the damage isn't lost — it
        // just isn't free.
        #expect(try !archive.verifyIntegrity().isClean)
    }

    @Test func anInterruptedWriteIsStandingAndRebaselineClearsIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())

        // What an interrupted mutation leaves: a sidecar the manifest has not
        // caught up on, and the marker. `open()` promotes the pair to the
        // archive's own state — the marker alone, with nothing behind it, it
        // settles (slice 65).
        let record = root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json")
        try (Data(contentsOf: record) + Data("\n".utf8)).write(to: record)
        try Data().write(to: root.appendingPathComponent(".index/\(MachineKey.current)/dirty"))
        let reopened = try Archive.open(at: root)
        #expect(try reopened.standingFindings().interruptedWriteSuspected)
        #expect(reopened.person(withID: person.uid) != nil)

        try reopened.rebaseline()
        #expect(try reopened.standingFindings().isEmpty)
    }
}
