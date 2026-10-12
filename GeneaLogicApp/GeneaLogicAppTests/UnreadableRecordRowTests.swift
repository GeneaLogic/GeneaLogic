import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 56 — a damaged record shows up as damaged, not as absent.
///
/// The rows are built from a path and nothing else (the record's own contents are
/// what failed to decode), so the parsing *is* the feature — get it wrong and the
/// row lands in the wrong list or doesn't appear at all, which is the bug this
/// slice exists to fix, returned by a different door.
@MainActor
@Suite struct UnreadableRecordRowTests {

    // MARK: - Parsing paths into rows

    // MARK: - What VoiceOver hears

    /// **The row is one combined element with a hand-written label, so a new
    /// affordance does not announce itself** (review finding, 59): 59's Restore
    /// was drawn but unspoken. The label says when there is a copy to restore, and
    /// the view declares a matching `accessibilityAction`.
    @Test func theLabelNamesTheRestoreOnlyWhenThereIsOne() throws {
        let row = try #require(UnreadableRecordRow("artifacts/deed-of-sale/record.json"))

        let restorable = row.accessibilityLabel(canRestore: true)
        #expect(restorable.contains(row.title))
        #expect(restorable.contains(row.label))
        #expect(restorable.contains(row.detail))
        #expect(restorable.lowercased().contains("restored"))

        // No copy, no mention of one — the same rule as the button itself.
        let unrestorable = row.accessibilityLabel(canRestore: false)
        #expect(unrestorable == "\(row.title), \(row.label). \(row.detail)")
        #expect(!unrestorable.lowercased().contains("restore"))
    }

    /// An older-format record is intact (slice 64): nothing on its row may read
    /// as damage, and nothing may point at a restore.
    @Test func anOlderFormatRecordIsNotDescribedAsDamage() throws {
        let row = try #require(
            UnreadableRecordRow(
                UnreadableRecord(
                    path: "conclusions/persons/PER-019fe97e-b57d-7029.json", reason: .olderFormat)))
        #expect(row.condition == .olderFormat)
        #expect(row.title == "Record in an older format")
        #expect(row.detail.contains("older archive format"))
        #expect(row.detail.contains("intact"))
        #expect(!row.detail.contains("couldn't be read"))
        #expect(!row.accessibilityLabel(canRestore: false).lowercased().contains("restore"))

        // The default is 55's reading, so every existing call site keeps its words.
        let damaged = try #require(UnreadableRecordRow("artifacts/deed-of-sale/record.json"))
        #expect(damaged.condition == .undecodable)
    }

    @Test func anArtifactRecordIsLabelledBySlug() throws {
        let row = try #require(UnreadableRecordRow("artifacts/deed-of-sale/record.json"))
        #expect(row.kind == .artifact)
        #expect(row.label == "deed-of-sale")
        #expect(row.title == "Unreadable record")
    }

    @Test func aPersonRecordIsLabelledByUID() throws {
        let row = try #require(
            UnreadableRecordRow("conclusions/persons/PER-019fe97e-b57d-7029.json"))
        #expect(row.kind == .person)
        #expect(row.label == "PER-019fe97e-b57d-7029")
    }

    /// Relationships, links and dismissals have no browse list, so they parse as
    /// `.other` and are reported by the banner instead of a row nobody would see.
    @Test func recordsWithoutABrowseListParseAsOther() throws {
        for path in [
            "conclusions/relationships/REL-1.json",
            "conclusions/links/LNK-1.json",
            "conclusions/dismissals/DIS-1.json",
        ] {
            let row = try #require(UnreadableRecordRow(path))
            #expect(row.kind == .other)
        }
    }

    @Test func aPathTheEngineWouldNeverWriteParsesAsNil() {
        #expect(UnreadableRecordRow("manifest.json") == nil)
        #expect(UnreadableRecordRow("artifacts/deed-of-sale/scan.tif") == nil)
        #expect(UnreadableRecordRow("") == nil)
    }

    @Test func theFileURLResolvesUnderTheArchiveRoot() throws {
        let row = try #require(UnreadableRecordRow("artifacts/deed-of-sale/record.json"))
        let root = URL(fileURLWithPath: "/tmp/Some.genea", isDirectory: true)
        #expect(row.fileURL(in: root).path == "/tmp/Some.genea/artifacts/deed-of-sale/record.json")
    }

    // MARK: - The model surfaces them, split by list

    /// Corrupts both records, then rebuilds through a *second* archive handle —
    /// a faithful stand-in for the CLI reindexing underneath the window (the same
    /// technique `MainActorResponsivenessTests` uses) — and drives 51's poll.
    ///
    /// **The rebuild is load-bearing, not incidental scaffolding.** The poll
    /// watches `PRAGMA data_version`, which moves only when a connection commits
    /// to the index; corrupting a file on disk commits nothing and is not noticed
    /// until something rebuilds (56's hand-test, and ARCHITECTURE §10.4). So this
    /// covers fork (e) for what it actually claims — damage another process
    /// *commits* — and not for damage that merely appears on disk.
    @Test func damageArrivingUnderAnOpenWindowIsNoticedAndSplitByList() throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        _ = try #require(model.archive).addArtifact(
            ArtifactDraft(title: "Deed", mediaType: .image))
        let person = try #require(model.archive).addPerson(
            PersonDraft(given: "Ada", surname: "Lovelace"))
        let slug = try #require(model.archive?.artifacts().first?.slug)
        #expect(!model.hasStandingDamage)

        try Data("not JSON".utf8).write(
            to: root.appendingPathComponent("artifacts/\(slug)/record.json"))
        try Data("not JSON".utf8).write(
            to: root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json"))

        let otherWriter = try Archive.open(at: root)
        _ = try otherWriter.rebuildIndex()

        model.refreshIfChangedExternally()

        #expect(model.hasStandingDamage)
        #expect(model.unreadableArtifacts.map(\.label) == [slug])
        #expect(model.unreadablePersons.map(\.label) == [person.uid.raw])
        #expect(model.unreadableOthers.isEmpty)

        // And the lists they vanished from are genuinely empty — which is exactly
        // why the placeholder rows have to exist.
        #expect(model.artifacts.isEmpty)
        #expect(model.persons.isEmpty)
    }

    /// The same findings must also be there for a window that opens *after* the
    /// damage — the ordinary case, and the one the hand-test walks.
    @Test func aWindowOpenedOnADamagedArchiveReportsItImmediately() throws {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }
        _ = try #require(seed.archive).addArtifact(
            ArtifactDraft(title: "Deed", mediaType: .image))
        let slug = try #require(seed.archive?.artifacts().first?.slug)
        try Data("not JSON".utf8).write(
            to: root.appendingPathComponent("artifacts/\(slug)/record.json"))
        _ = try #require(seed.archive).rebuildIndex()

        let fresh = ArchiveModel(url: root)
        fresh.load()

        #expect(fresh.hasStandingDamage)
        #expect(fresh.unreadableArtifacts.map(\.label) == [slug])
    }

    @Test func aHealthyArchiveHasNoDamageToReport() throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        _ = try #require(model.archive).addArtifact(
            ArtifactDraft(title: "Deed", mediaType: .image))

        #expect(!model.hasStandingDamage)
        #expect(model.unreadableArtifacts.isEmpty)
    }
}
