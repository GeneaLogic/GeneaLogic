import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 58d — the app half: a record whose file is gone, with a copy kept,
/// stands in its list as a "Missing record" row named from the copy, and offers
/// Restore and an undoable Delete. The Verify Integrity panel offers the same for
/// every kind, by one rule, and explains each record row the way the sidebar's
/// hover text does.
@MainActor
@Suite struct MissingRecordTests {

    /// A model whose one person's file was deleted, after the rebuild that kept
    /// its copy.
    private func modelWithAMissingPerson(undo: Bool = false) async throws -> (
        model: ArchiveModel, root: URL, path: String
    ) {
        let (model, root) = try AppTestSupport.makeModel(undo: undo)
        await model.act { model.createPerson(given: "Ada", surname: "Lovelace") }
        let person = try #require(model.persons.first)
        let path = "conclusions/persons/\(person.uid.raw).json"
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        await model.act { model.rebuildIndex() }
        return (model, root, path)
    }

    // MARK: - The row

    @Test func aMissingPersonIsPinnedAndNamedFromItsCopy() async throws {
        let (model, root, path) = try await modelWithAMissingPerson()
        defer { AppTestSupport.remove(root) }

        let row = try #require(model.unreadablePersons.first)
        #expect(model.unreadablePersons.count == 1)
        #expect(row.path == path)
        #expect(row.condition == .missing)
        #expect(row.title == "Missing record")
        #expect(!row.canReveal)
        let plan = try #require(model.repairPlans[path])
        #expect(plan.isDeletable)
        #expect(row.displayLabel(named: plan.recordLabel) == "Ada Lovelace")
        #expect(model.persons.isEmpty)
    }

    /// The banner can be up before the first sweep finishes, and must not fall
    /// through to "a change didn't finish": the vanished record is a missing file
    /// in 57's words, whether or not the sweep has said so yet.
    @Test func theBannerCountsTheMissingFileBeforeAnySweep() async throws {
        let (model, root, path) = try await modelWithAMissingPerson()
        defer { AppTestSupport.remove(root) }

        #expect(model.hasStandingDamage)
        let summary = try #require(
            FileDamageSummary.merging(nil, missing: model.standingFindings.vanished))
        #expect(summary.headline == "1 file is missing from this archive")
        #expect(summary.paths == [path])
        #expect(FileDamageSummary.merging(summary, missing: [path]) == summary)
        #expect(FileDamageSummary.merging(nil, missing: []) == nil)
    }

    @Test func restoringBringsThePersonBack() async throws {
        let (model, root, path) = try await modelWithAMissingPerson()
        defer { AppTestSupport.remove(root) }

        await model.act { model.repairRecord(atPath: path) }

        #expect(model.unreadablePersons.isEmpty)
        #expect(model.persons.count == 1)
        #expect(!model.hasStandingDamage)
        // Nothing was replaced, so there is no quarantine to report.
        #expect(model.actionInfo == nil)
    }

    /// Delete is undoable through the ordinary restore: ⌘Z brings the person back
    /// as a live record, ⌘⇧Z deletes them again.
    @Test func deletingIsUndoable() async throws {
        let (model, root, path) = try await modelWithAMissingPerson(undo: true)
        defer { AppTestSupport.remove(root) }

        await model.act { model.deleteVanishedRecord(atPath: path) }

        #expect(model.unreadablePersons.isEmpty)
        #expect(model.persons.isEmpty)
        #expect(model.standingFindings.isEmpty)
        #expect(model.actionError == nil)
        #expect(model.undoManager?.undoActionName == "Delete Record")

        await model.undoAndSettle()
        #expect(model.persons.map(\.displayName) == ["Ada Lovelace"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        #expect(!model.hasStandingDamage)

        await model.redoAndSettle()
        #expect(model.persons.isEmpty)
    }

    /// The model hands a refusal to the user rather than swallowing it — an
    /// unreadable record's file is still there, so it is not deleted.
    @Test func anUnreadableRecordIsNotDeleted() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }
        await model.act { model.createPerson(given: "Grace", surname: "Hopper") }
        let person = try #require(model.persons.first)
        let path = "conclusions/persons/\(person.uid.raw).json"
        try Data("{ not JSON".utf8).write(to: root.appendingPathComponent(path))
        await model.act { model.rebuildIndex() }

        await model.act { model.deleteVanishedRecord(atPath: path) }

        #expect(model.repairPlans[path] != nil)
        #expect(model.unreadablePersons.map(\.condition) == [.undecodable])
        let error = try #require(model.actionError)
        #expect(error.contains("isn't missing"))
    }

    // MARK: - The panel (fork h)

    private func plan(_ path: String, onDisk: Bool = false, label: String? = nil)
        -> Archive.RecordRepairPlan
    {
        Archive.RecordRepairPlan(
            path: path, uid: "REL-1", restoredSHA256: "a", recordedSHA256: "a",
            replacesFileOnDisk: onDisk, recordLabel: label)
    }

    @Test func thePanelOffersRestoreAndDeleteByOneRule() {
        let missing = "conclusions/relationships/REL-1.json"
        let unreadable = "conclusions/links/LNK-1.json"
        let plans = [missing: plan(missing), unreadable: plan(unreadable, onDisk: true)]

        let onMissing = IntegrityReportSheet.recordActions(
            for: .missingFile(path: missing), plans: plans)
        #expect(onMissing.restore != nil && onMissing.delete != nil)

        let onUnreadable = IntegrityReportSheet.recordActions(
            for: .unreadableRecord(path: unreadable, reason: .undecodable), plans: plans)
        #expect(onUnreadable.restore != nil && onUnreadable.delete == nil)

        // No plan, or a row that is not a record: nothing.
        let none = IntegrityReportSheet.recordActions(
            for: .missingFile(path: "artifacts/census/scan.jpg"), plans: plans)
        #expect(none.restore == nil && none.delete == nil)
        let older = IntegrityReportSheet.recordActions(
            for: .unreadableRecord(path: unreadable, reason: .olderFormat), plans: plans)
        #expect(older.restore == nil && older.delete == nil)
    }

    /// A record row in the panel carries what the sidebar says only on hover,
    /// named from the copy; a plain file row keeps the issue's own line.
    @Test func thePanelExplainsRecordRowsLikeTheSidebar() throws {
        let path = "artifacts/deed-of-sale/record.json"
        let issue = IntegrityReport.Issue.missingFile(path: path)
        let row = try #require(UnreadableRecordRow(missing: path))

        let detail = IntegrityReportSheet.detail(
            for: issue, plans: [path: plan(path, label: "Deed of Sale")])
        #expect(detail.hasPrefix(issue.detail))
        #expect(detail.contains("“Deed of Sale”"))
        #expect(detail.contains(row.detail))

        let unreadable = "conclusions/persons/PER-1.json"
        let unreadableDetail = IntegrityReportSheet.detail(
            for: .unreadableRecord(path: unreadable, reason: .undecodable),
            plans: [unreadable: plan(unreadable, onDisk: true)])
        #expect(unreadableDetail.contains("can be restored"))

        let file = IntegrityReport.Issue.missingFile(path: "artifacts/deed-of-sale/scan.jpg")
        #expect(IntegrityReportSheet.detail(for: file, plans: [:]) == file.detail)
    }

    /// The delete confirmation says how to take it back, and where an artifact goes.
    @Test func theDeleteConfirmationSaysItCanBeUndone() {
        let artifact = UnreadableRecordRowView.deleteMessage(named: "Census", kind: .artifact)
        #expect(artifact.contains("Trash"))
        #expect(artifact.contains("undo"))
        let person = UnreadableRecordRowView.deleteMessage(named: "Ada", kind: .person)
        #expect(person.contains("undo"))
        #expect(!person.contains("Trash"))
    }
}
