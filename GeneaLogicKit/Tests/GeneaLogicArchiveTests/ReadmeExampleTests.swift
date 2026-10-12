import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// The GeneaLogicKit example in the root `README.md`. The first test runs it; the second
/// checks that the README still says the same thing, so neither copy can drift alone. The
/// body between the markers is the README's, except for its two paths, which point into a
/// throwaway directory here.
@Suite struct ReadmeExampleTests {

    @Test func readmeExampleRuns() throws {
        let root = TestSupport.makeTempDirectory()
        let scan = root.appendingPathComponent("census.tif")
        try Data("not really a TIFF".utf8).write(to: scan)

        // ---- README ----
        let archive = try Archive.create(
            at: root.appendingPathComponent("Research.genea"), name: "Family Research")

        let census = try archive.addArtifact(
            ArtifactDraft(
                title: "1920 census, Ward 3",
                mediaType: .image,
                sourceAuthorityTier: .census,
                events: [Event(type: "Census", date: "1920-01-05", location: "Springfield")]
            ))
        try archive.attachFile(copyingFrom: scan, to: census.uid, role: .preservationMaster)

        for hit in archive.artifacts(matching: ArtifactQuery(text: "census")) {
            print(hit.uid, hit.title)  // ART-…  1920 census, Ward 3
        }
        // ---- end README ----

        let hits = archive.artifacts(matching: ArtifactQuery(text: "census"))
        #expect(hits.map(\.uid) == [census.uid])
        #expect(archive.artifact(withID: census.uid)?.files.count == 1)
    }

    /// Compares the README's code block with the body above, ignoring whitespace (the two
    /// wrap differently) and the README's `import` lines, after mapping this file's two
    /// paths back to the README's.
    @Test func readmeSaysWhatTheTestRuns() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot =
            thisFile
            .deletingLastPathComponent()  // …/Tests/GeneaLogicArchiveTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/GeneaLogicKit
            .deletingLastPathComponent()  // the repo root
        let readme = try String(
            contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let source = try String(contentsOf: thisFile, encoding: .utf8)

        let readmeSection = try #require(
            readme.components(separatedBy: "## Use GeneaLogicKit").dropFirst().first)
        let readmeBlock = try #require(
            readmeSection.components(separatedBy: "```swift\n").dropFirst().first?
                .components(separatedBy: "\n```").first)
        let readmeCode =
            readmeBlock
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("import ") }
            .joined(separator: "\n")

        // Built by concatenation so this function's own text doesn't contain the markers.
        let begin = "// ---- " + "README ----"
        let end = "// ---- " + "end README ----"
        let testCode = try #require(
            source.components(separatedBy: begin).dropFirst().first?
                .components(separatedBy: end).first)
        let mapped =
            testCode
            .replacingOccurrences(
                of: #"root.appendingPathComponent("Research.genea")"#,
                with: #"URL(filePath: "Research.genea")"#
            )
            .replacingOccurrences(
                of: "copyingFrom: scan,", with: #"copyingFrom: URL(filePath: "scans/census.tif"),"#)

        func squeezed(_ code: String) -> String { code.filter { !$0.isWhitespace } }
        #expect(squeezed(mapped) == squeezed(readmeCode))
    }
}
