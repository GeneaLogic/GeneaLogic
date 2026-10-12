import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 50d, the app end — stopping the wait for one file, and the note that
/// says you did.
///
/// The panel's rule is that a note is **not** a finding, so an abandonment leaves
/// the archive `isClean`. That is what makes the note easy to lose: the clean
/// branch of the sheet is a `ContentUnavailableView` with nowhere to put one, so
/// the surface that explains the decision would vanish exactly when it took
/// effect. These pin both halves.
@MainActor
@Suite struct AbandonedDeliveryTests {

    private func deliver(_ paths: [String], from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for path in paths {
            let target = destination.appendingPathComponent(path)
            try? fm.removeItem(at: target)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(path), to: target)
        }
    }

    private func clone(_ root: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("genealogic-other-machine-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    /// Stages the stuck state through the model: other edits a person both
    /// machines hold, only `manifest.json` crosses, and this window is left
    /// expecting a version nothing will bring.
    private func stage() throws -> (model: ArchiveModel, root: URL, other: URL, awaited: String) {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        let person = try #require(seed.archive).addPerson(
            PersonDraft(given: "Ada", surname: "Baseline"))

        let other = try clone(root)
        let otherMachine = try Archive.open(at: other)
        try otherMachine.updatePerson(person.uid) {
            $0.names.append(PersonName(type: .married, given: "Ada", surname: "OTHER-EDIT"))
        }
        try deliver(["manifest.json"], from: other, to: root)

        let model = ArchiveModel(url: root)
        model.load()
        return (model, root, other, "conclusions/persons/\(person.uid.raw).json")
    }

    /// The action clears the row, and the archive comes back clean — the state
    /// the panel's clean branch renders.
    @Test func abandoningADeliveryClearsTheFinding() async throws {
        let staged = try stage()
        defer {
            AppTestSupport.remove(staged.root)
            AppTestSupport.remove(staged.other)
        }
        let archive = try #require(staged.model.archive)
        #expect(try !archive.verifyIntegrity().isClean)

        staged.model.abandonDelivery(path: staged.awaited)
        await staged.model.writesSettled()

        #expect(staged.model.actionError == nil)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// **The trapdoor this closes.** A note is not a finding, so the report is
    /// clean — and the panel's clean branch has nowhere to draw one unless it
    /// looks. If `abandonedPaths` were ever folded into `issues` instead, this
    /// test would fail the other way, on `isClean`.
    @Test func theNoteSurvivesACleanReport() async throws {
        let staged = try stage()
        defer {
            AppTestSupport.remove(staged.root)
            AppTestSupport.remove(staged.other)
        }
        let archive = try #require(staged.model.archive)

        staged.model.abandonDelivery(path: staged.awaited)
        await staged.model.writesSettled()

        let report = try archive.verifyIntegrity()
        #expect(report.isClean, "a decision the user made is not a problem with the archive")
        #expect(report.abandonedPaths == [staged.awaited])
    }

    /// A refusal reaches the model's error channel rather than failing silently
    /// — the panel drains it into its own alert, since the window's cannot
    /// present from behind the sheet.
    @Test func aRefusalIsReportedRatherThanSwallowed() async throws {
        let staged = try stage()
        defer {
            AppTestSupport.remove(staged.root)
            AppTestSupport.remove(staged.other)
        }

        staged.model.abandonDelivery(path: "conclusions/persons/PER-nope.json")
        await staged.model.writesSettled()

        #expect(staged.model.actionError != nil)
    }
}
