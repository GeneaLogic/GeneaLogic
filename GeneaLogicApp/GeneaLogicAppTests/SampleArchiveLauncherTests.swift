import Foundation
import GeneaLogicModel
import GeneaLogicSample
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 74b — the welcome screen's sample is built once, then opened as it stands.
@Suite struct SampleArchiveLauncherTests {

    private func location() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleArchiveLauncherTests-\(UUID().uuidString)")
            .appendingPathComponent("Sample", isDirectory: true)
            .appendingPathComponent(SampleArchive.fileName, isDirectory: true)
    }

    @Test func theFirstOpenBuildsTheSample() throws {
        let url = try SampleArchiveLauncher.prepare(at: location())

        let archive = try Archive.open(at: url)
        #expect(archive.artifacts().count == 9)
    }

    /// An edit to the sample survives the next click; the button never rebuilds it.
    @Test func aLaterOpenKeepsTheEdits() throws {
        let url = try SampleArchiveLauncher.prepare(at: location())
        let added = try Archive.open(at: url).addPerson(PersonDraft(given: "Added", surname: "Later"))

        let again = try SampleArchiveLauncher.prepare(at: url)

        #expect(again == url)
        #expect(try Archive.open(at: again).person(withID: added.uid) != nil)
    }
}
