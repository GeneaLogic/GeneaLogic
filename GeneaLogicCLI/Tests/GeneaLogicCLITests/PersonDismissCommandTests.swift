import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// Coverage of `genea person dismiss` / `undismiss` / `dismissals` — slice 45m, the
/// headless half of the dismissal record (spec §6.6).
///
/// The record's semantics are `DismissalTests`' to prove. What these test is the CLI's own
/// contract: that a declined pair stops being printed by `person duplicates` **in a
/// separate process's worth of state** (each command here opens the archive afresh, which
/// is exactly the relaunch a session-only dismissal would not survive), the column shape a
/// script reads, and the reporting `person merge`/`person remove` owe a user who can't undo.
@Suite struct PersonDismissCommandTests {

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
        let root = TestSupport.makeTempDirectory(function: "Dismiss-\(UUID().uuidString)")
        let path = root.appendingPathComponent("Dismiss").path
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

    private struct Fixture {
        var archive: String
        var first: String
        var second: String
    }

    /// Two records for one Szlama Feldberg — a pair the matcher offers on its own.
    private func makeFixture() throws -> Fixture {
        let archive = try makeArchive()
        let a = try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1871")
        let b = try addPerson(archive, given: "Szlama", surname: "Feldberg", birth: "1871")
        return Fixture(archive: archive, first: min(a, b), second: max(a, b))
    }

    // MARK: - The pair stops being offered

    @Test func aDismissedPairIsNoLongerListedAsADuplicate() throws {
        let f = try makeFixture()
        #expect(try run(PersonDuplicatesCommand.self, [f.archive]).count == 1)

        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])

        #expect(try run(PersonDuplicatesCommand.self, [f.archive]).isEmpty)
    }

    @Test func undismissingReturnsThePairToTheList() throws {
        let f = try makeFixture()
        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])

        let removed = try run(PersonUndismissCommand.self, [f.archive, f.first, f.second])

        #expect(removed.count == 1)
        #expect(try run(PersonDuplicatesCommand.self, [f.archive]).count == 1)
    }

    /// Retracting something never declined is the state the caller asked for.
    @Test func undismissingAPairThatWasNeverDeclinedPrintsNothing() throws {
        let f = try makeFixture()
        #expect(try run(PersonUndismissCommand.self, [f.archive, f.first, f.second]).isEmpty)
    }

    /// The pair is unordered for `same-person`, so the argument order must not matter —
    /// a script feeding `person duplicates`' columns back in gets the same record either
    /// way, and never a second one.
    @Test func theArgumentOrderDoesNotMatterForASymmetricSubject() throws {
        let f = try makeFixture()

        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])
        try run(PersonDismissCommand.self, [f.archive, f.second, f.first])

        #expect(try run(PersonDismissalsCommand.self, [f.archive]).count == 1)
    }

    // MARK: - The registers

    /// Five columns, uid first — the shape every other `person` command prints in.
    @Test func dismissalsPrintsTheDeclinedClaimWithItsPair() throws {
        let f = try makeFixture()
        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])

        let lines = try run(PersonDismissalsCommand.self, [f.archive])

        #expect(lines.count == 1)
        let row = columns(lines[0])
        #expect(row.count == 5)
        #expect(row[0].hasPrefix("DSM-"))
        #expect(row[1] == "same-person")
        #expect(row[2] == f.first)
        #expect(row[3] == f.second)
        // The pair scored, so the declined confidence is on the record (45c).
        #expect(Int(row[4]) != nil)
    }

    /// A subject with no scorer behind it stores no number, and the column is empty
    /// rather than `0` — which would be a confidence the matcher never computed.
    @Test func anUnscoredSubjectPrintsAnEmptyConfidenceColumn() throws {
        let f = try makeFixture()
        try run(
            PersonDismissCommand.self,
            [f.archive, f.first, f.second, "--subject", "parent-child"])

        let row = columns(try run(PersonDismissalsCommand.self, [f.archive])[0])
        #expect(row[1] == "parent-child")
        #expect(row[4].isEmpty)
    }

    /// Scoped to one person, for a script asking "why is this person not being offered
    /// against anyone?"
    @Test func dismissalsCanBeFilteredToOnePerson() throws {
        let f = try makeFixture()
        let third = try addPerson(f.archive, given: "Fay", surname: "Hanner", birth: "1895")
        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])
        try run(PersonDismissCommand.self, [f.archive, f.first, third])

        #expect(try run(PersonDismissalsCommand.self, [f.archive]).count == 2)
        #expect(
            try run(PersonDismissalsCommand.self, [f.archive, "--person", third]).count == 1)
    }

    /// Declining one claim leaves the others open — 45l inherits this scoping.
    @Test func decliningARelationshipDoesNotForecloseTheDuplicate() throws {
        let f = try makeFixture()

        try run(
            PersonDismissCommand.self,
            [f.archive, f.first, f.second, "--subject", "parent-child"])

        #expect(try run(PersonDuplicatesCommand.self, [f.archive]).count == 1)
    }

    // MARK: - Failure paths

    @Test func dismissingAnUnknownPersonFails() throws {
        let f = try makeFixture()
        let stderr = try runExpectingFailure(
            PersonDismissCommand.self, [f.archive, f.first, "PER-nope"])
        #expect(stderr.contains("PER-nope"))
    }

    @Test func dismissingAPersonAgainstThemselvesFails() throws {
        let f = try makeFixture()
        try runExpectingFailure(PersonDismissCommand.self, [f.archive, f.first, f.first])
    }

    /// **A typo must not write a no-op record.** The subject vocabulary is open so that
    /// *reading* a later version's value works; minting one here is the opposite case —
    /// a subject nothing in this build produces is one nothing consumes, so it would
    /// suppress nothing, exit 0, and look like it worked. Found by 45m's `/code-review`.
    @Test func anUnknownSubjectIsRefusedRatherThanWritten() throws {
        let f = try makeFixture()

        let stderr = try runExpectingFailure(
            PersonDismissCommand.self,
            [f.archive, f.first, f.second, "--subject", "smae-person"])

        #expect(stderr.contains("same-person"))
        #expect(try run(PersonDismissalsCommand.self, [f.archive]).isEmpty)
        // …and the pair is still offered, which is what "nothing was written" means here.
        #expect(try run(PersonDuplicatesCommand.self, [f.archive]).count == 1)
    }

    /// The same guard on the way back out: an `undismiss` typo that silently matched
    /// nothing would report success while the real dismissal survived.
    @Test func undismissRefusesAnUnknownSubjectRatherThanNoOp() throws {
        let f = try makeFixture()
        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])

        try runExpectingFailure(
            PersonUndismissCommand.self,
            [f.archive, f.first, f.second, "--subject", "same-persons"])

        #expect(try run(PersonDismissalsCommand.self, [f.archive]).count == 1)
    }

    /// Human input is folded to a known case, so the spellings a person actually types
    /// reach the right value instead of minting an `.unknown` twin (the standing
    /// `parsingLeniently` rule).
    @Test func aCasedOrSpacedSubjectStillReachesTheKnownCase() throws {
        let f = try makeFixture()

        try run(
            PersonDismissCommand.self,
            [f.archive, f.first, f.second, "--subject", "Same-Person"])

        let row = columns(try run(PersonDismissalsCommand.self, [f.archive])[0])
        #expect(row[1] == "same-person")
    }

    // MARK: - What the neighbouring commands owe

    /// **The contradiction, in the report.** Merging a pair the user declined overrules an
    /// earlier human judgement, and a CLI has no undo to soften it — so the merge says so
    /// in its own words rather than dropping the record silently.
    @Test func mergeReportsTheDismissalItContradicts() throws {
        let f = try makeFixture()
        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])

        let text = try run(PersonMergeCommand.self, [f.archive, f.second, "--into", f.first])
            .joined(separator: "\n")

        #expect(text.contains("Dropped dismissal"))
        #expect(text.contains("contradicts"))
        #expect(try run(PersonDismissalsCommand.self, [f.archive]).isEmpty)
    }

    /// A dismissal naming a removed person keeps suppressing a suggestion, so the
    /// no-cascade warning counts it beside the relationships and links.
    @Test func removingAPersonReportsTheDismissalsLeftDangling() throws {
        let f = try makeFixture()
        try run(PersonDismissCommand.self, [f.archive, f.first, f.second])

        let text = try run(PersonRemoveCommand.self, [f.archive, f.second])
            .joined(separator: "\n")

        #expect(text.contains("1 dismissal(s)"))

        // …and `verify` finds it afterward, which is where the user is pointed.
        let verified = try run(VerifyCommand.self, [f.archive]).joined(separator: "\n")
        #expect(verified.contains("dismissal-endpoint"))
    }
}
