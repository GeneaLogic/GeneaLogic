import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// Coverage of `genea person duplicates` — slice 45j, the headless duplicate-detection
/// surface (ARCHITECTURE.md §4.1, §4.6).
///
/// The scoring is `DuplicateMatcherTests`' to prove and the pairwise pass is
/// `DuplicateCandidatesTests`'; what these test is the CLI's own contract — the column
/// shape a script reads, the two registers, and that a command whose neighbour is
/// `person merge` still writes nothing.
@Suite struct PersonDuplicatesCommandTests {

    // MARK: - Harness

    private func run<C: ArchiveSubcommand>(_ type: C.Type, _ args: [String]) throws -> [String] {
        let stdout = CollectingOutput()
        try C.parse(args).run(stdout: stdout, stderr: CollectingOutput())
        return stdout.allLines
    }

    @discardableResult
    private func runExpectingFailure<C: ArchiveSubcommand>(
        _ type: C.Type, _ args: [String], sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let stderr = CollectingOutput()
        do {
            try C.parse(args).run(stdout: CollectingOutput(), stderr: stderr)
            Issue.record("Expected the command to fail.", sourceLocation: sourceLocation)
        } catch {
            // Expected: every failure path throws a non-zero `ExitCode`.
        }
        return stderr.text
    }

    private func makeArchive() throws -> String {
        let root = TestSupport.makeTempDirectory(function: "Duplicates-\(UUID().uuidString)")
        let path = root.appendingPathComponent("Duplicates").path
        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        return path
    }

    private func addPerson(
        _ archive: String, given: String, surname: String, birth: String? = nil
    ) throws -> String {
        let uid = try run(
            PersonAddCommand.self, [archive, "--given", given, "--surname", surname])[
                0]
        if let birth {
            try run(
                FactAddCommand.self, [archive, "--person", uid, "--type", "birth", "--date", birth])
        }
        return uid
    }

    private func columns(_ line: String) -> [String] {
        line.components(separatedBy: "\t")
    }

    /// Two records for one Szlama Feldberg, plus somebody who is nobody's duplicate.
    private struct Fixture {
        var archive: String
        var first: String
        var second: String
    }

    private func makeFixture() throws -> Fixture {
        let archive = try makeArchive()
        let a = try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1871")
        let b = try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1871")
        try addPerson(archive, given: "Fay", surname: "Hanner", birth: "1895")
        // Canonical order is by uid, which is what the row prints.
        return Fixture(archive: archive, first: min(a, b), second: max(a, b))
    }

    // MARK: - The pipe register

    /// Five columns, the two uids first — what a script reads to feed `person merge`.
    @Test func printsTheFiveColumnRowWithUidsFirst() throws {
        let f = try makeFixture()

        let lines = try run(PersonDuplicatesCommand.self, [f.archive])

        #expect(lines.count == 1)
        let row = columns(lines[0])
        #expect(row.count == 5)
        #expect(row[0] == f.first)
        #expect(row[1] == f.second)
        #expect(Int(row[2]) != nil)
        #expect(row[3] == "Szlama Feldberg")
        #expect(row[4] == "Szlama Feldberg")
    }

    /// A person with no name still holds its column, so `cut -f5` can't shift left.
    @Test func anUnnamedPersonPrintsAPlaceholderNotAnEmptyColumn() throws {
        let archive = try makeArchive()
        // Two nameless persons score nothing, so one of the pair keeps a name.
        try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1871")
        let engine = try Archive.open(at: URL(fileURLWithPath: archive, isDirectory: true))
        try engine.addPerson(PersonDraft(names: []))

        let lines = try run(PersonDuplicatesCommand.self, [archive, "--min-confidence", "0"])

        // Whatever scores, no row may carry an empty middle column.
        for line in lines {
            let row = columns(line)
            #expect(row.count == 5)
            #expect(!row[3].isEmpty)
        }
    }

    @Test func anArchiveWithNoDuplicatesPrintsNothing() throws {
        let archive = try makeArchive()
        try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1871")
        try addPerson(archive, given: "Fay", surname: "Hanner", birth: "1895")

        #expect(try run(PersonDuplicatesCommand.self, [archive]).isEmpty)
    }

    // MARK: - The explain register

    /// The decomposed breakdown, **without the two GPS weights** — neither side of a
    /// person↔person comparison is a source, so there is nothing for them to measure and
    /// printing them would be inventing a figure.
    @Test func explainPrintsTheBreakdownAndNoSourceWeights() throws {
        let f = try makeFixture()

        let text = try run(PersonDuplicatesCommand.self, [f.archive, "--explain"])
            .joined(separator: "\n")

        #expect(text.contains(f.first))
        #expect(text.contains(f.second))
        #expect(text.contains("Confidence:"))
        #expect(text.contains("Dimensions:"))
        #expect(text.contains("name"))
        #expect(text.contains("Conflicts:"))
        #expect(!text.contains("Weights:"))
        #expect(!text.contains("source authority"))
        #expect(!text.contains("information quality"))
    }

    /// A dimension neither record states prints `(not assessed)`, never a zero — the
    /// matcher's central honesty rule, and it has to survive the trip through the CLI.
    @Test func explainReportsAnUnassessedDimensionAsNotAssessed() throws {
        let archive = try makeArchive()
        try addPerson(archive, given: "Szlama", surname: "Feldberg")
        try addPerson(archive, given: "Szlama", surname: "Feldberg")

        let text = try run(PersonDuplicatesCommand.self, [archive, "--explain"])
            .joined(separator: "\n")

        #expect(text.contains("birthYear") && text.contains("(not assessed)"))
    }

    /// The conflict sentences reach the reader unchanged — on this surface they are the
    /// lines that tell a grandson from his grandfather.
    @Test func explainPrintsConflictSentences() throws {
        let archive = try makeArchive()
        try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1871")
        try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1924")

        let text = try run(
            PersonDuplicatesCommand.self, [archive, "--explain", "--min-confidence", "0"]
        ).joined(separator: "\n")

        #expect(text.contains("birthYear: the first says"))
        #expect(text.contains("years apart"))
    }

    // MARK: - Flags

    @Test func minConfidenceFiltersAndLimitCaps() throws {
        let f = try makeFixture()

        #expect(
            try run(PersonDuplicatesCommand.self, [f.archive, "--min-confidence", "101"]).isEmpty)
        #expect(try run(PersonDuplicatesCommand.self, [f.archive, "--limit", "1"]).count == 1)
    }

    /// A non-positive limit is **refused**, not obeyed: an empty result from this command
    /// reads as "no duplicates in this archive", which is a reassuring thing to print
    /// because of a typo'd flag.
    @Test func aNonPositiveLimitIsRefused() throws {
        let f = try makeFixture()

        let message = try runExpectingFailure(
            PersonDuplicatesCommand.self, [f.archive, "--limit", "0"])

        #expect(message.contains("--limit must be at least 1"))
    }

    // MARK: - It suggests and never commits

    /// The neighbour command destroys a record; this one must not touch anything.
    @Test func nothingIsWritten() throws {
        let f = try makeFixture()
        let root = URL(fileURLWithPath: f.archive, isDirectory: true)

        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        try run(PersonDuplicatesCommand.self, [f.archive, "--explain"])
        let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        #expect(before == after)
        let engine = try Archive.open(at: root)
        #expect(engine.persons().count == 3)
    }

    /// The pair disappears once it has been merged — the loop the command exists to
    /// close, run end to end through the CLI.
    @Test func aMergedPairStopsBeingReported() throws {
        let f = try makeFixture()

        try run(PersonMergeCommand.self, [f.archive, f.second, "--into", f.first])

        #expect(try run(PersonDuplicatesCommand.self, [f.archive]).isEmpty)
    }
}
