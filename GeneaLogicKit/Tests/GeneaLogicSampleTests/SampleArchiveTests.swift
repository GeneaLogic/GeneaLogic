import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicSample

/// Slice 74b — the sample archive.
///
/// The sample is the stranger's first look, so these pin what it promises: it is a
/// sound archive, every part of the app has something in it, including Review, and a
/// build that fails leaves nothing behind.
@Suite struct SampleArchiveTests {
    private static func makeFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GeneaLogicSampleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// One sample, built once, for the tests that only read it.
    private static let shared: Result<URL, any Error> = Result {
        let url = try makeFolder().appendingPathComponent(SampleArchive.fileName)
        try SampleArchive.build(at: url)
        return url
    }

    private func sample() throws -> Archive {
        try Archive.open(at: Self.shared.get())
    }

    private func person(_ name: String, in archive: Archive) throws -> PersonID {
        try #require(archive.persons().first { $0.displayName == name }).uid
    }

    private func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - What the sample holds

    @Test func theSampleIsASoundArchive() throws {
        let archive = try sample()

        #expect(try archive.verifyIntegrity().isClean)
        #expect(archive.findDanglingReferences().isEmpty)
        #expect(archive.artifacts().count == 9)
        #expect(archive.persons().count == 12)
        #expect(archive.relationships().count == 15)
        #expect(archive.links().count == 23)
    }

    @Test func everyDocumentHasItsPage() throws {
        let archive = try sample()

        for summary in archive.artifacts() {
            let artifact = try #require(archive.artifact(withID: summary.uid))
            #expect(artifact.files.count == 1, "\(artifact.title)")
            let file = try #require(artifact.files.first)
            let url = try #require(archive.fileURL(of: file.uid, in: artifact.uid))
            #expect(FileManager.default.fileExists(atPath: url.path), "\(artifact.title)")
            #expect(file.originalName.hasSuffix(".jpg"), "\(artifact.title)")
        }
    }

    /// Eleven names are left unlinked, each with a suggestion: the six lines of the 1920
    /// census, three on the naturalization, two on the death certificate. The census's
    /// head is suggested as Marcus despite the clerk's *Honner*.
    @Test func reviewHasLinksToSuggest() throws {
        let archive = try sample()
        let census = try #require(archive.artifacts().first { $0.title.contains("1920") })
        let marcus = try person("Marcus Hanner", in: archive)

        #expect(archive.suggestLinks().count == 11)
        let suggestions = archive.suggestLinks(forArtifact: census.uid)
        #expect(suggestions.count == 6)
        let head = try #require(suggestions.first { $0.mention.localRef == "p1" })
        #expect(head.candidates.first?.personID == marcus)
    }

    @Test func reviewHasADuplicate() throws {
        let archive = try sample()
        let pair: Set = [
            try person("Marcus Hanner", in: archive), try person("Markus Hanaur", in: archive),
        ]

        let duplicates = archive.duplicateCandidates()
        #expect(duplicates.count == 1)
        #expect(duplicates.map { Set([$0.person1, $0.person2]) } == [pair])
    }

    /// The death certificate names Sidney's mother, and no relationship says so yet.
    @Test func reviewHasARelationshipToSuggest() throws {
        let archive = try sample()
        let gussie = try person("Gitla Sternfeld", in: archive)
        let sidney = try person("Zelig Feldberg", in: archive)

        let suggested = archive.suggestedRelationships()
        #expect(suggested.count == 1)
        #expect(suggested.first?.type == .parentChild)
        #expect(suggested.first?.person1 == gussie)
        #expect(suggested.first?.person2 == sidney)
    }

    // MARK: - Where it is built

    @Test func aSampleIsBuiltOnlyWhereNothingIs() throws {
        let url = try Self.makeFolder().appendingPathComponent(SampleArchive.fileName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        #expect(throws: SampleArchiveError.alreadyExists(url)) {
            try SampleArchive.build(at: url)
        }
        #expect(try contents(of: url.deletingLastPathComponent()) == [SampleArchive.fileName])
        #expect(try contents(of: url).isEmpty)
    }

    private struct Interrupted: Error {}

    @Test func aFailedBuildLeavesNothingBehind() throws {
        let folder = try Self.makeFolder()
        let url = folder.appendingPathComponent(SampleArchive.fileName)

        #expect(throws: Interrupted.self) {
            try SampleArchive.build(at: url, beforeMove: { throw Interrupted() })
        }
        #expect(try contents(of: folder).isEmpty)
    }

    /// Two windows asking at once: the one that loses the rename reports `alreadyExists`,
    /// which the app reads as "open that one", and its own build is gone.
    @Test func losingTheRaceIsAlreadyExists() throws {
        let folder = try Self.makeFolder()
        let url = folder.appendingPathComponent(SampleArchive.fileName)

        #expect(throws: SampleArchiveError.alreadyExists(url)) {
            try SampleArchive.build(
                at: url,
                beforeMove: {
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: false)
                })
        }
        #expect(try contents(of: folder) == [SampleArchive.fileName])
    }

    /// A build killed before it could clean up is swept by the next one, and a build that
    /// may still be running is not.
    @Test func anAbandonedBuildIsSwept() throws {
        let fileManager = FileManager.default
        let folder = try Self.makeFolder()
        let url = folder.appendingPathComponent(SampleArchive.fileName)
        let abandoned = ".\(SampleArchive.fileName).building-ABANDONED"
        let running = ".\(SampleArchive.fileName).building-RUNNING"
        for name in [abandoned, running] {
            try fileManager.createDirectory(
                at: folder.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-SampleArchive.abandonedAfter - 60)],
            ofItemAtPath: folder.appendingPathComponent(abandoned).path)

        try SampleArchive.build(at: url)

        #expect(try contents(of: folder) == [running, SampleArchive.fileName].sorted())
    }
}
