import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// Coverage of `genea match …` — slice 45d, the headless matcher surface
/// (ARCHITECTURE.md §4.6).
///
/// Driven like the other CLI suites (parse argv → run against a temp archive →
/// assert on captured stdout **and** on real on-disk engine state). The scoring
/// itself is slice 45's to prove and the projection is 45b/45c's; what these test is
/// the CLI's own contract — the column shape a script pipes on, the cases the two
/// suggestion directions can express, and the three review verbs writing (and
/// removing) what they say they do.
@Suite struct MatchCommandTests {

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

    private func makeArchive(named name: String = "Match") throws -> String {
        let root = TestSupport.makeTempDirectory(function: "\(name)-\(UUID().uuidString)")
        let path = root.appendingPathComponent(name).path
        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        return path
    }

    private func engine(_ path: String) throws -> Archive {
        try Archive.open(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func addArtifact(_ archive: String, title: String = "1912 Marriage Register") throws
        -> String
    {
        try run(
            AddCommand.self,
            [
                archive, "--title", title, "--media-type", "image",
                "--source-tier", "vital-record", "--source-derivation", "original",
            ])[0]
    }

    private func addMention(_ archive: String, on artifact: String, name: String) throws -> String {
        try run(MentionAddCommand.self, [archive, artifact, "--name", name])[0]
    }

    private func addPerson(_ archive: String, given: String, surname: String) throws -> String {
        try run(PersonAddCommand.self, [archive, "--given", given, "--surname", surname])[0]
    }

    /// The fixture nearly every test starts from: one record naming Marcus Hanner,
    /// one concluded Marcus Hanner, and one unrelated person who should never appear.
    private struct Fixture {
        var archive: String
        var artifact: String
        var ref: String
        var marcus: String
        var berek: String

        /// The `--artifact --mention --person` triple the review verbs take.
        var pair: [String] {
            ["--artifact", artifact, "--mention", ref, "--person", marcus]
        }
    }

    private func makeFixture() throws -> Fixture {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive)
        return Fixture(
            archive: archive,
            artifact: artifact,
            ref: try addMention(archive, on: artifact, name: "Marcus Hanner"),
            marcus: try addPerson(archive, given: "Marcus", surname: "Hanner"),
            berek: try addPerson(archive, given: "Berek", surname: "Sternfeld"))
    }

    private func columns(_ line: String) -> [String] {
        line.components(separatedBy: "\t")
    }

    // MARK: - suggest

    /// The person direction prints the six-column row, and columns 1–3 are exactly
    /// the triple the review verbs take — the promise a shell loop depends on.
    @Test func suggestForPersonPrintsThePipeableTriple() throws {
        let f = try makeFixture()

        let lines = try run(MatchSuggestCommand.self, [f.archive, "--person", f.marcus])

        #expect(lines.count == 1)
        let row = columns(lines[0])
        #expect(row[0] == f.artifact)
        #expect(row[1] == f.ref)
        #expect(row[2] == f.marcus)
        #expect(Int(row[3]) != nil)
        #expect(row[4] == "Marcus Hanner")
        #expect(row[5] == "Marcus Hanner")
    }

    /// The artifact direction asks the mirror question and prints the identical
    /// columns, so a script never branches on which direction it used.
    @Test func suggestForArtifactPrintsTheSameColumns() throws {
        let f = try makeFixture()

        let lines = try run(MatchSuggestCommand.self, [f.archive, "--artifact", f.artifact])

        #expect(lines.count == 1)
        #expect(Array(columns(lines[0])[0...2]) == [f.artifact, f.ref, f.marcus])
    }

    /// **The case a flat list of scored pairs cannot express** (45c's
    /// `MentionSuggestions`): an unresolved mention nothing matched is still a row.
    /// Without it, "no mentions", "all resolved" and "a name the archive has never
    /// seen" are one empty output — and only the third has work attached.
    ///
    /// The placeholder columns are `-`, not empty: consecutive tabs collapse under a
    /// shell `read`, and these absences are mid-row.
    @Test func suggestForArtifactReportsAMentionNothingMatched() throws {
        let f = try makeFixture()
        let stranger = try addMention(f.archive, on: f.artifact, name: "Chaja Rozenblum")

        let lines = try run(MatchSuggestCommand.self, [f.archive, "--artifact", f.artifact])

        #expect(lines.count == 2)
        let row = columns(lines[1])
        #expect(row[0] == f.artifact)
        #expect(row[1] == stranger)
        #expect(row[2] == "-")
        #expect(row[3] == "-")
        #expect(row[4] == "Chaja Rozenblum")
        #expect(row[5].contains("no candidate"))
    }

    /// The floor is a flag because finding the right one for an archive is what this
    /// command exists for. At zero, the pair the default hides is scored and shown.
    @Test func minConfidenceIsTunable() throws {
        let f = try makeFixture()
        _ = try addMention(f.archive, on: f.artifact, name: "Chaja Rozenblum")

        let atZero = try run(
            MatchSuggestCommand.self,
            [f.archive, "--artifact", f.artifact, "--min-confidence", "0"])

        // Every mention × every person now scores, so the mention that had no
        // candidate at the default floor has them here.
        #expect(atZero.count > 2)
        #expect(!atZero.contains { $0.contains("no candidate") })
    }

    /// `--limit` caps candidates **per mention** in the artifact direction — a global
    /// cap would silently starve later mentions of candidates.
    @Test func limitIsPerMentionForTheArtifactDirection() throws {
        let f = try makeFixture()
        _ = try addMention(f.archive, on: f.artifact, name: "Chaja Rozenblum")

        let lines = try run(
            MatchSuggestCommand.self,
            [f.archive, "--artifact", f.artifact, "--min-confidence", "0", "--limit", "1"])

        // Two mentions, one candidate each — not one row in total.
        #expect(lines.count == 2)
    }

    /// **A non-positive `--limit` is refused, not obeyed.** The engine clamps it to "no
    /// results", which here would print the *nothing-matched* row for a mention with a
    /// perfect candidate — a "this may be somebody new" signal produced by a flag.
    @Test func nonPositiveLimitIsRefused() throws {
        let f = try makeFixture()

        // Both routes a non-positive value can arrive by. `--limit=-1` is the one that
        // reaches the guard: with a space, ArgumentParser reads `-1` as an option name
        // and rejects the flag as valueless before any of this runs — also a refusal,
        // but the parser's, so the guard has to exist for the equals form regardless.
        for bad in [["--limit", "0"], ["--limit=-1"]] {
            let error = try runExpectingFailure(
                MatchSuggestCommand.self, [f.archive, "--artifact", f.artifact] + bad)
            #expect(error.contains("--limit must be at least 1"))
        }

        // The row that would have lied, proving the candidate was there all along.
        let honest = try run(
            MatchSuggestCommand.self, [f.archive, "--artifact", f.artifact, "--limit", "1"])
        #expect(columns(honest[0])[2] == f.marcus)
    }

    /// An empty recorded name renders as `-`, not as an empty column: it sits *between*
    /// the score and the person, and a mid-row blank collapses under a shell `read`
    /// exactly like the placeholders. Nothing validates `nameAsRecorded`, so this is
    /// reachable rather than theoretical.
    @Test func anEmptyRecordedNameStillHoldsItsColumn() throws {
        let f = try makeFixture()
        let blank = try addMention(f.archive, on: f.artifact, name: "")

        let lines = try run(
            MatchSuggestCommand.self,
            [f.archive, "--artifact", f.artifact, "--min-confidence", "0"])
        let row = try #require(columns(lines.first { columns($0)[1] == blank } ?? ""))

        #expect(row.count == 6)
        #expect(row[4] == "-")
    }

    /// A typo'd uid must not read as "nothing matched". The engine answers an unknown
    /// person with an empty result, which is right for a non-throwing query and wrong
    /// to print at someone tuning a threshold.
    @Test func suggestRejectsAnUnknownTarget() throws {
        let f = try makeFixture()

        let personError = try runExpectingFailure(
            MatchSuggestCommand.self, [f.archive, "--person", "PER-nope"])
        #expect(personError.contains("PER-nope"))

        let artifactError = try runExpectingFailure(
            MatchSuggestCommand.self, [f.archive, "--artifact", "ART-nope"])
        #expect(artifactError.contains("ART-nope"))
    }

    @Test func suggestNeedsExactlyOneDirection() throws {
        let f = try makeFixture()

        #expect(
            try runExpectingFailure(MatchSuggestCommand.self, [f.archive])
                .contains("--person or --artifact"))
        #expect(
            try runExpectingFailure(
                MatchSuggestCommand.self,
                [f.archive, "--person", f.marcus, "--artifact", f.artifact]
            ).contains("not both"))
    }

    // MARK: - explain

    /// The decomposed breakdown, one dimension per line — and an unassessed dimension
    /// says so rather than printing a zero. *Not assessed* is not *assessed and
    /// failed*, and this fixture's record is silent about everything but the name.
    @Test func explainPrintsTheDimensionsAndMarksTheUnassessedOnes() throws {
        let f = try makeFixture()

        let lines = try run(MatchExplainCommand.self, [f.archive] + f.pair)
        let text = lines.joined(separator: "\n")

        #expect(lines[0].contains(f.artifact))
        #expect(lines[0].contains("\"Marcus Hanner\""))
        #expect(lines[0].contains("1912 Marriage Register"))
        #expect(lines[1].contains(f.marcus))
        #expect(text.contains("Confidence: "))
        #expect(text.contains("name        exact     100"))
        #expect(text.contains("birthYear   (not assessed)"))
        #expect(text.contains("birthPlace  (not assessed)"))
        #expect(text.contains("spouseName  (not assessed)"))
        #expect(text.contains("parents     (not assessed)"))
        #expect(text.contains("source authority"))
        #expect(text.contains("information quality"))
    }

    /// A birth year a few years off is a `within` match with its delta glossed in
    /// years — the dimension whose `delta` actually carries a unit.
    @Test func explainGlossesTheBirthYearDelta() throws {
        let f = try makeFixture()
        try run(
            MentionFactAddCommand.self,
            [f.archive, f.artifact, "--ref", f.ref, "--type", "Birth", "--date", "1890"])
        try run(
            FactAddCommand.self,
            [f.archive, "--person", f.marcus, "--type", "Birth", "--date", "1892"])

        let text = try run(MatchExplainCommand.self, [f.archive] + f.pair).joined(separator: "\n")

        #expect(text.contains("birthYear   within"))
        #expect(text.contains("2 years apart"))
        // The name row carries the keyer that ran, and `known-variant` — wider than
        // the kind column — must overflow rather than be cut down to a lie.
        #expect(
            MatchFormat.dimensionLine(
                "name", MatchDimension(kind: .knownVariant, score: 70), algorithm: "x"
            )
            .contains("known-variant "))
    }

    /// A relational dimension that didn't agree still prints — the record named a
    /// spouse, and that they disagree is a lead — but it says it wasn't scored. A bare
    /// `none 0` beside a confidence figure reads as *this is what dragged it down*,
    /// and since 45g it drags nothing: relational evidence corroborates, never
    /// penalizes.
    @Test func aRelationalMissSaysItWasNotScored() {
        let missed = MatchDimension(kind: .none, score: 0)
        #expect(
            MatchFormat.dimensionLine("spouseName", missed, relational: true)
                .contains("(not scored)"))
        // A fact dimension's zero *is* scored — and explains itself as a conflict.
        #expect(!MatchFormat.dimensionLine("birthYear", missed).contains("(not scored)"))
        // An agreeing relational dimension carries no such caveat.
        #expect(
            !MatchFormat.dimensionLine(
                "spouseName", MatchDimension(kind: .exact, score: 100), relational: true
            ).contains("(not scored)"))
    }

    /// Place depth moved out of `kind` in 45h, so `within` alone no longer says what
    /// agreed — the granularity is glossed beside it, verbatim, including a value this
    /// build doesn't know.
    @Test func aPlaceDimensionGlossesItsGranularity() {
        #expect(
            MatchFormat.dimensionLine(
                "birthPlace", MatchDimension(kind: .within, score: 80, granularity: .specific)
            ).contains("to specific"))
        // A pre-45h `county`, relocated on read, must still reach the reader.
        #expect(
            MatchFormat.dimensionLine(
                "birthPlace",
                MatchDimension(kind: .within, score: 50, granularity: .unknown("county"))
            ).contains("to county"))
        // A dimension without one says nothing extra.
        #expect(
            !MatchFormat.dimensionLine("birthPlace", MatchDimension(kind: .exact, score: 100))
                .contains("to "))
    }

    /// A conflict is written by the matcher as a sentence precisely so it can be
    /// printed at a reviewer unchanged.
    @Test func explainPrintsConflictsVerbatim() throws {
        let f = try makeFixture()
        try run(
            MentionFactAddCommand.self,
            [f.archive, f.artifact, "--ref", f.ref, "--type", "Birth", "--date", "1830"])
        try run(
            FactAddCommand.self,
            [f.archive, "--person", f.marcus, "--type", "Birth", "--date", "1892"])

        let text = try run(MatchExplainCommand.self, [f.archive] + f.pair).joined(separator: "\n")

        #expect(text.contains("Conflicts:"))
        #expect(text.contains("birthYear: record says 1830"))
    }

    /// **`explain` applies no skip rules**, which is the point: it answers "why did
    /// this pair stop being offered?", and the answer is usually a verdict on disk.
    /// A rejected pair still explains, and the stored verdict is printed with it.
    @Test func explainWorksOnARejectedPairAndReportsTheVerdict() throws {
        let f = try makeFixture()
        let uid = try run(MatchRejectCommand.self, [f.archive] + f.pair)[0]

        let text = try run(MatchExplainCommand.self, [f.archive] + f.pair).joined(separator: "\n")

        #expect(text.contains("Recorded verdict:"))
        #expect(text.contains(uid))
        #expect(text.contains("human-rejected"))
    }

    @Test func explainReportsWhichRecordIsMissing() throws {
        let f = try makeFixture()

        #expect(
            try runExpectingFailure(
                MatchExplainCommand.self,
                [f.archive, "--artifact", f.artifact, "--mention", "p99", "--person", f.marcus]
            ).contains("p99"))
        #expect(
            try runExpectingFailure(
                MatchExplainCommand.self,
                [f.archive, "--artifact", f.artifact, "--mention", f.ref, "--person", "PER-nope"]
            ).contains("PER-nope"))
    }

    // MARK: - confirm

    /// The record `confirm` writes is deliberately mixed: a human decided
    /// (`.humanConfirmed`), a machine proposed (`createdBy: .machine`, with the
    /// matcher's tool identifier), and the stored breakdown is **the matcher's real
    /// reasoning** — not `link()`'s honest minimum, and not rounded up because someone
    /// agreed.
    @Test func confirmStoresTheMatchersRealBreakdown() throws {
        let f = try makeFixture()
        try run(
            MentionFactAddCommand.self,
            [f.archive, f.artifact, "--ref", f.ref, "--type", "Birth", "--date", "1890"])
        try run(
            FactAddCommand.self,
            [f.archive, "--person", f.marcus, "--type", "Birth", "--date", "1892"])

        let uid = try run(
            MatchConfirmCommand.self, [f.archive] + f.pair + ["--reviewed-by", "R. Feldberg"])[0]
        #expect(uid.hasPrefix("LNK-"))

        let link = try #require(try engine(f.archive).evidenceLink(withID: EvidenceLinkID(uid)))
        #expect(link.reviewStatus == .humanConfirmed)
        #expect(link.reviewedBy == "R. Feldberg")
        #expect(link.provenance.createdBy == .machine)
        #expect(link.provenance.tool != nil)
        // The dimension `link()` would never have filled in, at the score the matcher
        // actually computed.
        #expect(link.match.birthYear?.kind == .within)
        #expect(link.match.birthYear?.delta == 2)
        #expect(link.aggregateConfidence < 100)
    }

    /// A confirmation resolves the mention **for everyone** — it is no longer a
    /// question, so it leaves the queue in both directions.
    @Test func confirmingRemovesTheMentionFromTheQueue() throws {
        let f = try makeFixture()
        try run(MatchConfirmCommand.self, [f.archive] + f.pair)

        #expect(try run(MatchSuggestCommand.self, [f.archive, "--person", f.marcus]).isEmpty)
        #expect(try run(MatchSuggestCommand.self, [f.archive, "--artifact", f.artifact]).isEmpty)
    }

    /// `--reviewed-by` omitted leaves `reviewedBy` `nil` rather than inventing an
    /// identity — `genea link`'s rule, shared by all three review verbs.
    @Test func confirmWithoutAReviewerLeavesTheFieldNil() throws {
        let f = try makeFixture()
        let uid = try run(MatchConfirmCommand.self, [f.archive] + f.pair)[0]

        let link = try #require(try engine(f.archive).evidenceLink(withID: EvidenceLinkID(uid)))
        #expect(link.reviewedBy == nil)
    }

    // MARK: - reject

    /// A rejection is a record because the alternative is a matcher with no memory:
    /// suggestions are ephemeral, so declining one has to leave a tombstone or the
    /// identical pair is offered forever.
    @Test func rejectWritesATombstoneAndForeclosesThePair() throws {
        let f = try makeFixture()

        let uid = try run(MatchRejectCommand.self, [f.archive] + f.pair)[0]
        let link = try #require(try engine(f.archive).evidenceLink(withID: EvidenceLinkID(uid)))
        #expect(link.reviewStatus == .humanRejected)
        #expect(link.isRejection)
        #expect(link.match.name.kind == .exact)

        #expect(try run(MatchSuggestCommand.self, [f.archive, "--person", f.marcus]).isEmpty)
    }

    /// **Scoped to the pair, not the mention.** Rejecting this candidate forecloses
    /// one pair; the mention stays unresolved and every other candidate stays open —
    /// which is exactly what the no-candidate row then has to report.
    @Test func rejectLeavesTheMentionUnresolved() throws {
        let f = try makeFixture()
        try run(MatchRejectCommand.self, [f.archive] + f.pair)

        let lines = try run(MatchSuggestCommand.self, [f.archive, "--artifact", f.artifact])

        #expect(lines.count == 1)
        let row = columns(lines[0])
        #expect(row[1] == f.ref)
        #expect(row[2] == "-")
        // …and the row says *why* it is empty. A candidate is dropped for two
        // reasons and the engine's result cannot tell them apart, so blaming only
        // the floor would send a user lowering `--min-confidence` forever when the
        // fix is one `match unreject`.
        #expect(row[5].contains("1 rejected on this mention"))
    }

    /// A tombstone is never a citation: it must not surface as a source on the person
    /// it says the mention is *not*.
    @Test func aRejectionIsNotASource() throws {
        let f = try makeFixture()
        try run(MatchRejectCommand.self, [f.archive] + f.pair)

        let shown = try run(PersonShowCommand.self, [f.archive, f.marcus])
        let sources = shown.drop { $0 != "Sources:" }
        #expect(Array(sources) == ["Sources:", "  (none)"])
    }

    /// A pair holds **one** verdict, so changing your mind replaces the tombstone
    /// rather than stacking a second record — and the CLI says what it displaced.
    @Test func confirmingAfterARejectionReplacesTheVerdict() throws {
        let f = try makeFixture()
        let rejection = try run(MatchRejectCommand.self, [f.archive] + f.pair)[0]

        let lines = try run(MatchConfirmCommand.self, [f.archive] + f.pair)

        #expect(lines.count == 2)
        #expect(lines[1].contains(rejection))
        #expect(lines[1].contains("human-rejected"))

        let links = try engine(f.archive).links(for: PersonID(f.marcus), includeRejected: true)
        #expect(links.count == 1)
        #expect(links[0].reviewStatus == .humanConfirmed)
    }

    // MARK: - unreject

    /// Un-rejecting is deleting the tombstone — the pair returns to the queue, and
    /// the mention is scored against that person again.
    @Test func unrejectReturnsThePairToTheQueue() throws {
        let f = try makeFixture()
        let uid = try run(MatchRejectCommand.self, [f.archive] + f.pair)[0]

        let removed = try run(MatchUnrejectCommand.self, [f.archive] + f.pair)
        #expect(removed.count == 1)
        #expect(removed[0].contains(uid))
        #expect(columns(removed[0]).count == 4)

        let again = try run(MatchSuggestCommand.self, [f.archive, "--person", f.marcus])
        #expect(again.count == 1)
        #expect(columns(again[0])[2] == f.marcus)
        #expect(try engine(f.archive).evidenceLink(withID: EvidenceLinkID(uid)) == nil)
    }

    /// **A confirmation is refused, not removed.** Both are `EvidenceLink`s and the
    /// CLI has no undo, so a command that says "unreject" must not quietly un-resolve
    /// a mention — the error names `genea unlink` instead.
    @Test func unrejectRefusesToDeleteAConfirmation() throws {
        let f = try makeFixture()
        let uid = try run(MatchConfirmCommand.self, [f.archive] + f.pair)[0]

        let error = try runExpectingFailure(MatchUnrejectCommand.self, [f.archive] + f.pair)
        #expect(error.contains("human-confirmed"))
        #expect(error.contains("genea unlink"))

        #expect(try engine(f.archive).evidenceLink(withID: EvidenceLinkID(uid)) != nil)
    }

    @Test func unrejectOnAPairWithNoVerdictSaysSo() throws {
        let f = try makeFixture()

        let error = try runExpectingFailure(MatchUnrejectCommand.self, [f.archive] + f.pair)
        #expect(error.contains("No rejection recorded"))
        #expect(error.contains(f.ref))
    }

    /// **Every tombstone on the pair, not the first one.** One verdict per pair is
    /// enforced on the write paths, so this state needs a foreign writer to reach —
    /// but the promise `unreject` makes is that the pair comes back, and honoring it
    /// only for the first record would fail silently, the user's sole evidence being a
    /// suggestion that never reappears.
    @Test func unrejectClearsEveryTombstoneOnThePair() throws {
        let f = try makeFixture()
        let first = try run(MatchRejectCommand.self, [f.archive] + f.pair)[0]

        // A second tombstone written straight to `conclusions/links/`, as another tool
        // (or a version predating the one-verdict rule) would leave behind.
        let archive = try engine(f.archive)
        let original = try #require(archive.evidenceLink(withID: EvidenceLinkID(first)))
        var duplicate = original
        duplicate.uid = EvidenceLinkID("LNK-\(UUID().uuidString.lowercased())")
        let url = URL(fileURLWithPath: f.archive, isDirectory: true)
            .appendingPathComponent("conclusions/links/\(duplicate.uid.raw).json")
        try JSONEncoder().encode(duplicate).write(to: url)
        try archive.rebuildIndex()

        let removed = try run(MatchUnrejectCommand.self, [f.archive] + f.pair)

        #expect(removed.count == 2)
        #expect(try engine(f.archive).links(for: PersonID(f.marcus), includeRejected: true).isEmpty)
        #expect(try run(MatchSuggestCommand.self, [f.archive, "--person", f.marcus]).count == 1)
    }

    // MARK: - The loop this slice exists for

    /// The whole triage cycle through the CLI: suggest → explain → reject → unreject
    /// → confirm, ending with the mention resolved and the link readable as a source.
    @Test func theReviewLoopRoundTrips() throws {
        let f = try makeFixture()

        let suggested = try run(MatchSuggestCommand.self, [f.archive, "--artifact", f.artifact])
        let triple = Array(columns(suggested[0])[0...2])
        let pair = [
            "--artifact", triple[0], "--mention", triple[1], "--person", triple[2],
        ]

        #expect(
            try run(MatchExplainCommand.self, [f.archive] + pair)
                .contains { $0.hasPrefix("Confidence: ") })

        try run(MatchRejectCommand.self, [f.archive] + pair)
        #expect(try run(MatchSuggestCommand.self, [f.archive, "--person", f.marcus]).isEmpty)

        try run(MatchUnrejectCommand.self, [f.archive] + pair)
        #expect(try run(MatchSuggestCommand.self, [f.archive, "--person", f.marcus]).count == 1)

        let uid = try run(MatchConfirmCommand.self, [f.archive] + pair)[0]
        let shown = try run(PersonShowCommand.self, [f.archive, f.marcus])
        #expect(shown.contains { $0.contains(uid) && $0.contains("Marcus Hanner") })
    }
}
