import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 60 — a change that reached the files without any process committing it.
///
/// Slice 51's poll watches `PRAGMA data_version`, which moves when another
/// *process* commits through the engine. A `record.json` delivered by cloud sync
/// from another machine, restored from a backup, or merged in by `git` commits
/// nothing, so that token never moves — the window would show the old record
/// indefinitely. The engine's witness closes it, and this is the app end of it.
@MainActor
@Suite struct DeliveredChangeTests {

    /// Everything the other machine's engine wrote for a change, copied over this
    /// one's archive: the record **and** the manifest describing it. That pairing
    /// is what a sync provider actually delivers, and it is what the witness
    /// notices — a bare edit of the record alone is deliberately *not* adopted
    /// (see `ManifestWitnessTests`).
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

    /// **The assertion that fails without slice 60.** Nothing here commits to this
    /// archive's index, so `externalChangeToken()` never moves and the poll's own
    /// comparison never fires; the only thing that can notice is the witness.
    @Test func anEditDeliveredFromAnotherMachineReachesTheOpenWindow() async throws {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }
        _ = try #require(seed.archive).addArtifact(
            ArtifactDraft(title: "Before", mediaType: .image))
        let slug = try #require(seed.archive?.artifacts().first?.slug)
        let uid = try #require(seed.archive?.artifacts().first?.uid)

        // A window opened on the archive as it stands, the way the app would be
        // when the delivery lands underneath it.
        let model = ArchiveModel(url: root)
        model.load()

        let other = try clone(root)
        defer { AppTestSupport.remove(other) }
        let otherMachine = try Archive.open(at: other)
        _ = try otherMachine.updateMetadata(of: uid) { $0.title = "After" }

        try deliver(
            ["artifacts/\(slug)/record.json", "manifest.json"], from: other, to: root)

        // Still showing the old title: nothing has looked yet.
        #expect(model.artifacts.first?.title == "Before")

        model.refreshIfChangedExternally()
        await model.reconcileSettled()

        #expect(model.artifacts.first?.title == "After")
    }

    /// **Slice 60c, at the surface it was reported from.** Damage that predates a
    /// delivery kept the banner up until the delivery started, then went quiet for
    /// its whole duration — and because the summary changed to `nil` and back, the
    /// dismissal the user had already made was reset when it returned.
    ///
    /// The engine change is the whole of the fix; this is the app end of it, and
    /// the equality is the load-bearing part: `ArchiveContainerView` resets the
    /// dismissal `.onChange(of: model.fileDamage)`.
    @Test func theDamageBannerKeepsSpeakingWhileADeliveryIsInFlight() async throws {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }
        _ = try #require(seed.archive).addArtifact(
            ArtifactDraft(title: "Before", mediaType: .image))

        // Cloned before the damage, so the other machine's manifest carries the
        // bystander's *settled* hash — it is not part of what it is sending.
        let other = try clone(root)
        defer { AppTestSupport.remove(other) }

        let bystander = root.appendingPathComponent(
            "\(ArchiveLayout.schemaDirectoryName)/\(ArchiveLayout.schemaSpecFileName)")
        try (Data(contentsOf: bystander) + Data("rot".utf8)).write(to: bystander)

        let model = ArchiveModel(url: root)
        model.load()
        await model.fileSweepSettled()
        let beforeTheDelivery = try #require(model.fileDamage)

        let otherMachine = try Archive.open(at: other)
        _ = try otherMachine.addPerson(PersonDraft(given: "Ada", surname: "Lovelace"))
        try deliver(["manifest.json"], from: other, to: root)

        model.refreshIfChangedExternally()
        await model.reconcileSettled()
        await model.fileSweepSettled()

        #expect(model.archive?.deliveryIsInFlight == true)
        #expect(
            model.fileDamage == beforeTheDelivery,
            "the banner went quiet for the delivery, resetting a dismissal on the way back")
    }

    /// The poll must stay cheap when nothing arrived — it runs once a second for
    /// as long as a window is open.
    @Test func aQuietArchiveIsUndisturbedByThePoll() async throws {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }
        _ = try #require(seed.archive).addArtifact(
            ArtifactDraft(title: "Steady", mediaType: .image))
        _ = try #require(seed.archive).addPerson(
            PersonDraft(given: "Ada", surname: "Lovelace"))

        let model = ArchiveModel(url: root)
        model.load()

        for _ in 0..<5 {
            model.refreshIfChangedExternally()
            await model.reconcileSettled()
        }

        #expect(model.artifacts.map(\.title) == ["Steady"])
        #expect(model.persons.count == 1)
        #expect(!model.hasStandingDamage)
    }
}

/// Slice 60, second `/code-review` — the Verify panel must have somewhere to put
/// every finding it can be handed.
@MainActor
@Suite struct IntegrityPanelCoverageTests {

    /// **The trapdoor this closes:** adding `.arriving` to `Severity` compiled
    /// cleanly and matched none of the panel's three hand-written filters, so an
    /// archive whose only findings were arrivals was not `isClean`, skipped the
    /// "Archive Is Intact" branch, and rendered a `List` with zero sections — a
    /// blank sheet, on the very surface the banner stays silent in favour of.
    @Test func everySeverityHasASection() {
        let covered = Set(IntegrityReportSheet.sections.map(\.severity))
        #expect(covered == Set(IntegrityReport.Issue.Severity.allCases))
    }

    /// And the finding actually lands in one, rather than in a section that
    /// happens to exist.
    @Test func anArrivingFindingIsRoutedToItsOwnSection() {
        let issue = IntegrityReport.Issue.awaitingDelivery(path: "conclusions/persons/PER-1.json")
        let section = IntegrityReportSheet.sections.first { $0.severity == issue.severity }
        #expect(section?.title == "Still Arriving")
    }
}
