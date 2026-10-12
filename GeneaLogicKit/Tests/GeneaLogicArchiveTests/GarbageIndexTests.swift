import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// A garbage `.index/…/index.sqlite` is *unusable*, not stale (slice 63,
/// fork f). `sqlite3_open` and `PRAGMA user_version` read only the header, so a
/// file with a valid header and corrupt pages passed both, and the archive then
/// failed to open from inside the in-place rebuild — `database disk image is
/// malformed`. `quick_check` on open reads every page, and a failure recreates the
/// file the way a missing or unopenable one already did.
@Suite struct GarbageIndexTests {

    private func indexURL(in root: URL) -> URL {
        ArchiveLayout.indexDatabaseURL(in: root)
    }

    private func archiveWithTwoArtifacts() throws -> (URL, [String]) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "One"))
        _ = try archive.addArtifact(.sample(title: "Two"))
        return (root, archive.artifacts().map(\.title).sorted())
    }

    /// Deterministic garbage, so a failure reproduces.
    private func garbage(count: Int, seed: UInt64) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
    }

    @Test func corruptPagesPastTheHeaderAreRecreatedOnOpen() throws {
        let (root, titles) = try archiveWithTwoArtifacts()
        let url = indexURL(in: root)
        var bytes = try Data(contentsOf: url)
        #expect(bytes.count > 8192, "the index should span several pages")
        // Keep the first page — header, schema, user_version — and scribble on the
        // rest: the shape that passed the header-only checks.
        bytes.replaceSubrange(4096..<bytes.count, with: garbage(count: bytes.count - 4096, seed: 1))
        try bytes.write(to: url)

        let reopened = try Archive.open(at: root)
        #expect(reopened.artifacts().map(\.title).sorted() == titles)
        #expect(try reopened.verifyIntegrity().issues.isEmpty)
        #expect(try ArchiveIndex.open(at: url).passesQuickCheck())
    }

    @Test func randomBytesAreRecreatedOnOpen() throws {
        let (root, titles) = try archiveWithTwoArtifacts()
        try Data(garbage(count: 65_536, seed: 7)).write(to: indexURL(in: root))
        #expect(try Archive.open(at: root).artifacts().map(\.title).sorted() == titles)
    }

    @Test func truncatedToHeaderOnlyIsRecreatedOnOpen() throws {
        let (root, titles) = try archiveWithTwoArtifacts()
        let url = indexURL(in: root)
        try Data(try Data(contentsOf: url).prefix(100)).write(to: url)
        #expect(try Archive.open(at: root).artifacts().map(\.title).sorted() == titles)
    }

    @Test func emptyFileIsRecreatedOnOpen() throws {
        let (root, titles) = try archiveWithTwoArtifacts()
        try Data().write(to: indexURL(in: root))
        #expect(try Archive.open(at: root).artifacts().map(\.title).sorted() == titles)
    }

    /// The check is not a second rebuild trigger for a healthy file: an index that
    /// passes it is used as-is, which `SQLiteIndexTests` pins by mtime — this pins
    /// the answer itself.
    @Test func healthyIndexPassesQuickCheck() throws {
        let (root, _) = try archiveWithTwoArtifacts()
        #expect(try ArchiveIndex.open(at: indexURL(in: root)).passesQuickCheck())
    }
}
