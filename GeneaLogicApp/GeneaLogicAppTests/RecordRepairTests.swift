import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 59 — the app half: a damaged row offers a restore exactly when the
/// archive kept something to restore from, and the placeholder becomes a real
/// record when it runs.
@MainActor
@Suite struct RecordRepairTests {

    /// A model whose one person has a corrupted sidecar and a preserved copy —
    /// the state the placeholder row is showing when the user reaches for the
    /// button.
    private func modelWithABrokenPerson() async throws -> (
        model: ArchiveModel, root: URL, path: String
    ) {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        await model.act { model.createPerson(given: "Ada", surname: "Lovelace") }
        let person = try #require(model.persons.first)
        let path = "conclusions/persons/\(person.uid.raw).json"

        try Data("{ not JSON".utf8).write(to: root.appendingPathComponent(path))
        await model.act { model.rebuildIndex() }
        return (model, root, path)
    }

    // MARK: - The offer exists only where it can be honoured (fork b)

    @Test func aDamagedRecordWithAPreservedCopyOffersARestore() async throws {
        let (model, root, path) = try await modelWithABrokenPerson()
        defer { AppTestSupport.remove(root) }

        #expect(model.unreadablePersons.map(\.path) == [path])
        let plan = try #require(model.repairPlans[path])
        #expect(plan.isByteExact)
        #expect(!plan.requiresExplicitAcceptance)
    }

    /// A record that never decoded was never indexed, so nothing was kept — the
    /// row is damage with no action, exactly as 56 shipped it.
    @Test func aDamagedRecordWithNoCopyOffersNothing() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        let path = "conclusions/persons/PER-never-decoded.json"
        try Data("{ garbage".utf8).write(to: root.appendingPathComponent(path))
        await model.act { model.rebuildIndex() }

        #expect(model.unreadablePersons.map(\.path) == [path])
        #expect(model.repairPlans[path] == nil)
    }

    // MARK: - Running it

    /// The loop from the banner: the placeholder row goes, the person is in the
    /// list, and the user is told where the damaged file went.
    @Test func restoringTurnsThePlaceholderIntoARealRecord() async throws {
        let (model, root, path) = try await modelWithABrokenPerson()
        defer { AppTestSupport.remove(root) }

        await model.act { model.repairRecord(atPath: path) }

        #expect(model.unreadablePersons.isEmpty)
        #expect(model.repairPlans.isEmpty)
        #expect(model.persons.count == 1)
        #expect(!model.hasStandingDamage)
        let info = try #require(model.actionInfo)
        #expect(info.contains(".damaged/"))
    }

    /// The engine refuses an inexact restore that was not accepted, and the app
    /// surfaces that rather than swallowing it — the button that can promise
    /// something and the button that cannot are not the same button.
    @Test func anInexactRestoreIsRefusedUntilAccepted() async throws {
        let (model, root, path) = try await modelWithABrokenPerson()
        defer { AppTestSupport.remove(root) }

        // Drop the manifest entry, so there is nothing to prove the copy against.
        let manifestURL = root.appendingPathComponent("manifest.json")
        var manifest =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
            as! [String: Any]
        var files = manifest["files"] as! [[String: Any]]
        files.removeAll { ($0["path"] as? String) == path }
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL)
        await model.act { model.rebuildIndex() }

        let plan = try #require(model.repairPlans[path])
        #expect(plan.requiresExplicitAcceptance)

        await model.act { model.repairRecord(atPath: path) }
        #expect(model.actionError != nil)
        #expect(model.unreadablePersons.map(\.path) == [path])

        await model.act {
            model.repairRecord(atPath: path, acceptingInexactRestore: true)
        }
        #expect(model.unreadablePersons.isEmpty)
        #expect(model.persons.count == 1)
    }
}
