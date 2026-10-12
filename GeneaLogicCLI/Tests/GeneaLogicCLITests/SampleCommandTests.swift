import ArgumentParser
import Foundation
import GeneaLogicArchive
import Testing

@testable import GeneaLogicCLI

/// Slice 74b — `genea sample`. What the sample holds is the engine's test
/// (`SampleArchiveTests`); this pins the command around it.
@Suite struct SampleCommandTests {
    @Test func sampleCreatesAnArchiveThatOpens() throws {
        let path = TestSupport.makeTempDirectory().appendingPathComponent("Sample.genea").path

        let out = CollectingOutput()
        try SampleCommand.parse([path]).run(stdout: out, stderr: CollectingOutput())
        #expect(out.allLines == ["Created the sample archive at \(path)"])

        let archive = try Archive.open(at: URL(fileURLWithPath: path))
        #expect(archive.artifacts().count == 9)
    }

    @Test func sampleRefusesAPathThatExists() throws {
        let path = TestSupport.makeTempDirectory().path

        let err = CollectingOutput()
        #expect(throws: ExitCode.failure) {
            try SampleCommand.parse([path]).run(stdout: CollectingOutput(), stderr: err)
        }
        #expect(err.text.contains("already exists"))
    }
}
