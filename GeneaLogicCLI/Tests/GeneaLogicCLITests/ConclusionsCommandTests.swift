import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// Coverage of the Phase-3 conclusions surface added in slice 44b — persons,
/// mentions, relationships, evidence links, facts and the trash — driven the same
/// way `CLICommandTests` drives the Phase-1 commands (parse argv → run against a
/// temp archive → assert on captured output and on engine state).
///
/// Beyond checking the CLI, these are the **second consumer** of the conclusions
/// API the slice exists to provide: they exercise it without any of the app's
/// assumptions (no `UndoManager`, no `@Observable` model, no main actor), which
/// is what de-risks the Linux/Vapor reuse in Phase 4.
@Suite struct ConclusionsCommandTests {

    // MARK: - Harness

    /// Runs an `ArchiveSubcommand` and returns its stdout lines.
    private func run<C: ArchiveSubcommand>(_ type: C.Type, _ args: [String]) throws -> [String] {
        let stdout = CollectingOutput()
        try C.parse(args).run(stdout: stdout, stderr: CollectingOutput())
        return stdout.allLines
    }

    /// Runs an `ArchiveSubcommand` expected to fail, returning what it wrote to
    /// stderr. Fails the test if the command unexpectedly succeeds.
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

    /// A fresh archive with no records, returning its path.
    private func makeArchive(named name: String = "Conclusions") throws -> String {
        let root = TestSupport.makeTempDirectory(function: "\(name)-\(UUID().uuidString)")
        let path = root.appendingPathComponent(name).path
        try CreateCommand.parse([path]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        return path
    }

    /// Opens `path` with the engine directly, to assert on real on-disk state
    /// rather than on what the CLI claimed it did.
    private func engine(_ path: String) throws -> Archive {
        try Archive.open(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func addPerson(_ archive: String, given: String, surname: String) throws -> String {
        try run(PersonAddCommand.self, [archive, "--given", given, "--surname", surname])[0]
    }

    // MARK: - person add / ls / show / set / rm

    /// `person add` mints a `PER-` uid and stores a birth name; `list` prints the
    /// pipe-friendly `<uid>\t<display name>`.
    @Test func personAddThenLs() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")
        #expect(uid.hasPrefix("PER-"))

        let listed = try run(PersonListCommand.self, [archive])
        #expect(listed == ["\(uid)\tAnna Meyer"])

        let person = try engine(archive).person(withID: PersonID(uid))
        #expect(person?.names.count == 1)
        #expect(person?.names.first?.type == .birth)
        #expect(person?.names.first?.given == "Anna")
        #expect(person?.names.first?.full == "Anna Meyer")
    }

    /// A person with no usable name lists with an **empty** second column rather
    /// than a placeholder, so `cut -f2` can't mistake decoration for a real name.
    @Test func namelessPersonListsWithEmptyNameColumn() throws {
        let archive = try makeArchive()
        // `person add` requires a name, so make the nameless case through the
        // engine — it's a state the format allows and `list` has to render.
        let created = try engine(archive).addPerson(PersonDraft())

        let listed = try run(PersonListCommand.self, [archive])
        #expect(listed == ["\(created.uid.raw)\t"])
    }

    /// `person list --match` goes through the engine's `persons(matching:)`, so it
    /// matches *every* name a person carries, not just the display one.
    @Test func personLsMatchSearchesAllNames() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        _ = try addPerson(archive, given: "Otto", surname: "Schmidt")

        try run(
            PersonNameAddCommand.self,
            [archive, anna, "--surname", "Braun", "--name-type", "married"])

        #expect(try run(PersonListCommand.self, [archive, "--match", "Schmidt"]).count == 1)
        let byMarriedName = try run(PersonListCommand.self, [archive, "--match", "Braun"])
        #expect(byMarriedName.map { $0.split(separator: "\t")[0] } == [anna[...]])
    }

    /// A person carries several names, so `person name add` appends rather than
    /// replacing — the birth name survives, and the *display* name still prefers
    /// it over the newly-added married one.
    @Test func personNameAddAppendsWithoutDisturbingTheBirthName() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")

        try run(
            PersonNameAddCommand.self,
            [archive, uid, "--given", "Anna", "--surname", "Braun", "--name-type", "married"])

        let person = try engine(archive).person(withID: PersonID(uid))
        #expect(person?.names.map(\.type) == [.birth, .married])
        #expect(person?.names.last?.full == "Anna Braun")
        #expect(try run(PersonListCommand.self, [archive]) == ["\(uid)\tAnna Meyer"])
    }

    /// `person name set` edits only the fields passed, leaving the rest of the
    /// name alone — the "apply what was passed" rule `set-meta` established.
    @Test func personNameSetAppliesOnlyPassedFields() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")

        try run(PersonNameSetCommand.self, [archive, uid, "--surname", "Braun"])

        let name = try engine(archive).person(withID: PersonID(uid))?.names.first
        #expect(name?.given == "Anna")
        #expect(name?.surname == "Braun")
        #expect(name?.type == .birth)
        // `full` is what every consumer displays, so a rename that left it stale
        // would be invisible everywhere and the record self-contradicting.
        #expect(name?.full == "Anna Braun")
        #expect(try run(PersonListCommand.self, [archive]) == ["\(uid)\tAnna Braun"])
    }

    /// A `full` the *author* typed carries information the parts don't, so editing
    /// a part must not clobber it — only a `full` we synthesized is derived data.
    @Test func personNameSetPreservesAnAuthoredFullName() throws {
        let archive = try makeArchive()
        let uid = try run(
            PersonAddCommand.self,
            [archive, "--given", "Anna", "--surname", "Meyer", "--full", "Anna Maria von Meyer"]
        )[0]

        try run(PersonNameSetCommand.self, [archive, uid, "--surname", "Braun"])

        let name = try engine(archive).person(withID: PersonID(uid))?.names.first
        #expect(name?.surname == "Braun")
        #expect(name?.full == "Anna Maria von Meyer")
    }

    /// Editing past the end of the names array is an error, not a silent append —
    /// a stale index usually means the caller is addressing a removed name (adding
    /// is `person name add`'s job). The record is left untouched.
    @Test func personNameSetRejectsOutOfRangeIndex() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")

        let stderr = try runExpectingFailure(
            PersonNameSetCommand.self, [archive, uid, "--index", "3", "--given", "X"])
        #expect(stderr.contains("No name at index 3"))

        let person = try engine(archive).person(withID: PersonID(uid))
        #expect(person?.names.count == 1)
        #expect(person?.names.first?.given == "Anna")
    }

    /// `person name set` requires at least one field to change.
    @Test func personNameSetRequiresAField() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")
        let stderr = try runExpectingFailure(PersonNameSetCommand.self, [archive, uid])
        #expect(stderr.contains("--given"))
    }

    /// `person name remove` drops a name by index; removing the last one is allowed
    /// (the format permits a nameless person, and `list` renders it).
    @Test func personNameRm() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")
        try run(PersonNameAddCommand.self, [archive, uid, "--surname", "Braun"])

        try run(PersonNameRemoveCommand.self, [archive, uid, "--index", "0"])
        #expect(
            try engine(archive).person(withID: PersonID(uid))?.names.map(\.surname) == ["Braun"])

        let stderr = try runExpectingFailure(
            PersonNameRemoveCommand.self, [archive, uid, "--index", "7"])
        #expect(stderr.contains("No name at index 7"))
    }

    /// `person show` renders names, facts, relationships (phrased from this
    /// person's side) and the artifacts citing them.
    @Test func personShowRendersTheWholeGraph() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let ella = try addPerson(archive, given: "Ella", surname: "Meyer")
        try run(
            FactAddCommand.self, [archive, "--person", anna, "--type", "Birth", "--date", "1892"])
        try run(RelateCommand.self, [archive, "--parent", anna, "--child", ella])

        let shown = try run(PersonShowCommand.self, [archive, anna]).joined(separator: "\n")
        #expect(shown.contains("Anna Meyer (birth)"))
        #expect(shown.contains("[0] Birth  1892"))
        // Anna is the parent, so Ella is listed as her *child*.
        #expect(shown.contains("child  \(ella) Ella Meyer"))
        // …and the same relationship reads as "parent" from Ella's side. Asserting
        // only the parent's side let a hardcoded `return "child"` pass the suite.
        let fromElla = try run(PersonShowCommand.self, [archive, ella]).joined(separator: "\n")
        #expect(fromElla.contains("parent  \(anna) Anna Meyer"))
        #expect(shown.contains("Sources:"))
    }

    /// Removing a person doesn't cascade (§2.3): the relationships and links that
    /// named them survive as dangling records, and the command says how many — the
    /// consequence is reported at the moment it happens, not left for `verify`.
    @Test func personRmLeavesDanglingRecordsAndReportsThem() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let ella = try addPerson(archive, given: "Ella", surname: "Meyer")
        try run(RelateCommand.self, [archive, "--parent", anna, "--child", ella])

        let output = try run(PersonRemoveCommand.self, [archive, anna]).joined(separator: "\n")
        #expect(output.contains("Removed \(anna)"))
        #expect(output.contains("1 relationship(s)"))

        let opened = try engine(archive)
        #expect(opened.person(withID: PersonID(anna)) == nil)
        #expect(opened.relationships().count == 1, "the relationship survives as a dangle")

        // And the dangle renders honestly from the surviving side.
        let shown = try run(PersonShowCommand.self, [archive, ella]).joined(separator: "\n")
        #expect(shown.contains("\(anna) (deleted person)"))
    }

    // MARK: - relate / unrelate

    /// `--parent`/`--child` map onto the §4.5 storage convention resolved in slice
    /// 43: `person1Uid` is the parent, `person2Uid` the child. This is the test
    /// that pins the convention from the CLI's side.
    @Test func relateStoresParentAsPerson1() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let ella = try addPerson(archive, given: "Ella", surname: "Meyer")

        let uid = try run(RelateCommand.self, [archive, "--parent", anna, "--child", ella])[0]
        #expect(uid.hasPrefix("REL-"))

        let relationship = try engine(archive).relationship(withID: RelationshipID(uid))
        #expect(relationship?.type == .parentChild)
        #expect(relationship?.person1Uid.raw == anna)
        #expect(relationship?.person2Uid.raw == ella)
        #expect(
            relationship?.facts.isEmpty == true, "no --nature means unspecified, not biological")
    }

    /// `--nature` rides `Relationship.facts` (slice 44f), and is accepted
    /// case-insensitively like every other open-vocabulary option.
    @Test func relateRecordsParentChildNature() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let ella = try addPerson(archive, given: "Ella", surname: "Meyer")

        let uid = try run(
            RelateCommand.self,
            [archive, "--parent", anna, "--child", ella, "--nature", "adoptiveparent"])[0]

        let relationship = try engine(archive).relationship(withID: RelationshipID(uid))
        #expect(relationship?.facts.map(\.type) == [.adoptiveParent])
    }

    /// A `--nature` that isn't a parent-child qualifier is a mistake worth
    /// catching, not a value worth preserving.
    @Test func relateRejectsNonParentChildNature() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let ella = try addPerson(archive, given: "Ella", surname: "Meyer")

        let stderr = try runExpectingFailure(
            RelateCommand.self,
            [archive, "--parent", anna, "--child", ella, "--nature", "Marriage"])
        #expect(stderr.contains("parent-child qualifier"))
    }

    /// A couple takes exactly two `--partner`s, and its endpoints are symmetric.
    @Test func relateCoupleAndUnrelate() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let otto = try addPerson(archive, given: "Otto", surname: "Meyer")

        let uid = try run(
            RelateCommand.self, [archive, "--partner", anna, "--partner", otto])[0]
        #expect(try engine(archive).relationship(withID: RelationshipID(uid))?.type == .couple)

        // Both sides see it as "partner".
        for subject in [anna, otto] {
            let shown = try run(PersonShowCommand.self, [archive, subject]).joined(separator: "\n")
            #expect(shown.contains("partner"))
        }

        try run(UnrelateCommand.self, [archive, uid])
        #expect(try engine(archive).relationships().isEmpty)
        // Unrelating leaves the persons alone.
        #expect(try engine(archive).persons().count == 2)
    }

    /// Mixing the two relationship shapes, or half-specifying either, is refused
    /// rather than guessed at.
    @Test func relateRejectsAmbiguousFlags() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")

        #expect(
            try runExpectingFailure(RelateCommand.self, [archive, "--parent", anna])
                .contains("must be given together"))
        #expect(
            try runExpectingFailure(RelateCommand.self, [archive, "--partner", anna])
                .contains("exactly two"))
        #expect(
            try runExpectingFailure(
                RelateCommand.self, [archive, "--parent", anna, "--partner", anna]
            ).contains("not both"))
    }

    // MARK: - facts

    /// A fact type given in any casing folds to the known case rather than
    /// becoming an `.unknown` twin that renders identically but never compares
    /// equal — the drift the 42c follow-up fixed on the app side.
    @Test func factTypeIsParsedCaseInsensitively() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")

        try run(FactAddCommand.self, [archive, "--person", uid, "--type", "birth"])

        let fact = try engine(archive).person(withID: PersonID(uid))?.facts.first
        #expect(fact?.type == .birth)
        #expect(fact?.type != .unknown("birth"))
    }

    /// `--date` accepts the genealogist shorthands the app's date field does and
    /// stores canonical EDTF.
    @Test func factDateNormalizesShorthand() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")

        try run(
            FactAddCommand.self,
            [
                archive, "--person", uid, "--type", "Birth", "--date", "abt 1892", "--place",
                "Chicago",
            ])

        let fact = try engine(archive).person(withID: PersonID(uid))?.facts.first
        #expect(fact?.date == "1892~")
        #expect(fact?.place == "Chicago")
    }

    /// An unparseable date is kept verbatim as free text, never rejected —
    /// genealogy has to allow the unparseable.
    @Test func factKeepsUnparseableDateAsFreeText() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")

        try run(
            FactAddCommand.self,
            [archive, "--person", uid, "--type", "Birth", "--date", "the year of the flood"])

        #expect(
            try engine(archive).person(withID: PersonID(uid))?.facts.first?.date
                == "the year of the flood")
    }

    /// A couple's marriage lives on the relationship, not duplicated onto each
    /// spouse (§4.5) — and `fact add --relationship` is how the CLI writes it.
    @Test func coupleFactLivesOnTheRelationship() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let otto = try addPerson(archive, given: "Otto", surname: "Meyer")
        let rel = try run(RelateCommand.self, [archive, "--partner", anna, "--partner", otto])[0]

        try run(
            FactAddCommand.self,
            [archive, "--relationship", rel, "--type", "Marriage", "--date", "June 1912"])

        let opened = try engine(archive)
        let fact = opened.relationship(withID: RelationshipID(rel))?.facts.first
        #expect(fact?.type == .marriage)
        #expect(fact?.date == "1912-06")
        #expect(opened.person(withID: PersonID(anna))?.facts.isEmpty == true)
    }

    /// Known fact types are scoped to the store that fits them: a marriage isn't a
    /// person fact, and a birth isn't a couple fact. (An *unknown* type still
    /// passes — the open vocabulary must keep round-tripping.)
    @Test func factTypeIsScopedToItsStore() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let otto = try addPerson(archive, given: "Otto", surname: "Meyer")
        let rel = try run(RelateCommand.self, [archive, "--partner", anna, "--partner", otto])[0]

        #expect(
            try runExpectingFailure(
                FactAddCommand.self, [archive, "--person", anna, "--type", "Marriage"]
            ).contains("isn't a fact about a person"))
        #expect(
            try runExpectingFailure(
                FactAddCommand.self, [archive, "--relationship", rel, "--type", "Birth"]
            ).contains("isn't a fact about a couple"))

        try run(FactAddCommand.self, [archive, "--person", anna, "--type", "Enumeration"])
        #expect(
            try engine(archive).person(withID: PersonID(anna))?.facts.map(\.type)
                == [.unknown("Enumeration")])
    }

    /// `fact add` needs exactly one target.
    @Test func factRequiresExactlyOneTarget() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")

        #expect(
            try runExpectingFailure(FactAddCommand.self, [archive, "--type", "Birth"])
                .contains("Specify --person or --relationship"))
        #expect(
            try runExpectingFailure(
                FactAddCommand.self,
                [archive, "--person", anna, "--relationship", "REL-x", "--type", "Birth"]
            ).contains("not both"))
    }

    /// `fact remove` addresses facts by the index `person show` prints; an
    /// out-of-range index errors and leaves the record untouched.
    @Test func factRmByIndex() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")
        try run(FactAddCommand.self, [archive, "--person", uid, "--type", "Birth"])
        try run(FactAddCommand.self, [archive, "--person", uid, "--type", "Death"])

        try run(FactRemoveCommand.self, [archive, "--person", uid, "--index", "0"])
        #expect(try engine(archive).person(withID: PersonID(uid))?.facts.map(\.type) == [.death])

        let stderr = try runExpectingFailure(
            FactRemoveCommand.self, [archive, "--person", uid, "--index", "5"])
        #expect(stderr.contains("No fact at index 5"))
        #expect(try engine(archive).person(withID: PersonID(uid))?.facts.count == 1)
    }

    // MARK: - mentions & links (the evidence→conclusion bridge)

    /// `mention add` mints the lowest unused `p<n>`, and reuses a freed one rather
    /// than drifting upward.
    @Test func mentionLocalRefsAreMintedAndReused() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")

        let first = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Anna Meyer"])[0]
        let second = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Otto Meyer"])[0]
        #expect([first, second] == ["p1", "p2"])

        try run(MentionRemoveCommand.self, [archive, artifact, "--ref", "p1"])
        let reused = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Ella Meyer"])[0]
        #expect(reused == "p1")
    }

    /// `--quality` is a *closed* vocabulary, so an unrecognized value is rejected
    /// with the valid list rather than preserved.
    ///
    /// It's conformed to `ExpressibleByArgument` (as `attach` does for `FileRole`),
    /// so the rejection happens at **parse** time — which is why this asserts on the
    /// parse error rather than on stderr from `run`. The payoff is the valid values
    /// also land in `--help` and shell completions, which the hand-rolled check this
    /// replaced could not provide.
    @Test func mentionRejectsUnknownClosedVocabularyValues() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")

        var message = ""
        do {
            _ = try MentionAddCommand.parse(
                [archive, artifact, "--name", "Anna", "--quality", "probably"])
            Issue.record("Expected parsing to reject the quality.")
        } catch {
            message = MentionAddCommand.message(for: error)
        }
        #expect(message.contains("'probably' is invalid"))
        #expect(message.contains("secondary"))

        // …and a valid value in any casing is accepted, storing the canonical form.
        let ref = try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Anna", "--quality", "Primary"])[0]
        let mention = try engine(archive).artifact(withID: ArtifactID(artifact))?
            .personsMentioned.first { $0.localRef == ref }
        #expect(mention?.informationQuality == .primary)
    }

    /// `--role`, by contrast, is an **open** vocabulary as of slice 44h: a register
    /// naming a role the vocabulary doesn't list must be recordable, not rejected —
    /// the whole reason the closed enum was reclassified (it would previously have
    /// made the record fail to *load*, let alone be written).
    @Test func mentionAcceptsAnyRoleAndFoldsKnownOnes() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "Metrical register")

        // A known role in any casing folds to the canonical case, rather than
        // minting an `.unknown("Witness")` twin that renders identically but never
        // compares equal.
        let known = try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Anna", "--role", "Witness"])[0]
        // A role standard in metrical registers, added as a known case in 44h.
        let register = try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Chaim", "--role", "godparent"])[0]
        // …and one nobody enumerated, preserved verbatim.
        let exotic = try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Sura", "--role", "marriage-broker"])[0]

        let mentions = try #require(
            engine(archive).artifact(withID: ArtifactID(artifact))?.personsMentioned)
        #expect(mentions.first { $0.localRef == known }?.role == .witness)
        #expect(mentions.first { $0.localRef == register }?.role == .godparent)
        #expect(mentions.first { $0.localRef == exotic }?.role == .unknown("marriage-broker"))
    }

    /// The mention-scoped facts that close §10.6: what *this* record says about
    /// *this* person, which is the only way a multi-person document can say whose
    /// birth year 1892 is.
    @Test func mentionFactsRecordWhatADocumentSaysAboutOnePerson() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "Metrical register page 14")
        let groom = try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Majer Sternfeld", "--role", "subject"])[0]
        let bride = try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Sura Rozen", "--role", "spouse"])[0]

        // Shorthand normalizes to canonical EDTF exactly as `fact add` does, and the
        // minted index leads so it composes with `mention fact remove --index`.
        let added = try run(
            MentionFactAddCommand.self,
            [
                archive, artifact, "--ref", groom, "--type", "Birth",
                "--date", "abt 1892", "--place", "Łomża",
            ])[0]
        #expect(added.hasPrefix("0\t"))
        try run(
            MentionFactAddCommand.self,
            [archive, artifact, "--ref", bride, "--type", "Birth", "--date", "1895"])

        let mentions = try #require(
            engine(archive).artifact(withID: ArtifactID(artifact))?.personsMentioned)
        let groomFacts = try #require(mentions.first { $0.localRef == groom }?.facts)
        #expect(groomFacts.count == 1)
        #expect(groomFacts[0].type == .birth)
        #expect(groomFacts[0].date == "1892~")
        #expect(groomFacts[0].place == "Łomża")
        // Absent quality means "inherit the mention's", not `.undetermined`.
        #expect(groomFacts[0].informationQuality == nil)
        // The two births are attributed separately — the whole point.
        #expect(mentions.first { $0.localRef == bride }?.facts.first?.date == "1895")

        // Per-field GPS quality when the record warrants it (§4.6).
        try run(
            MentionFactAddCommand.self,
            [
                archive, artifact, "--ref", groom, "--type", "Death", "--date", "1948",
                "--quality", "secondary",
            ])
        let withQuality = try #require(
            engine(archive).artifact(withID: ArtifactID(artifact))?
                .personsMentioned.first { $0.localRef == groom }?.facts.last)
        #expect(withQuality.informationQuality == .secondary)

        try run(
            MentionFactRemoveCommand.self,
            [archive, artifact, "--ref", groom, "--index", "0"])
        let remaining = try engine(archive).artifact(withID: ArtifactID(artifact))?
            .personsMentioned.first { $0.localRef == groom }?.facts
        #expect(remaining?.count == 1)
    }

    /// A value-bearing fact (occupation, physical description) carries its information
    /// in `--value`, not a date or place. The value persists and `show` renders it
    /// (slice 44i).
    @Test func mentionFactRecordsAValueBearingFact() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "Declaration of Intention")
        let ref = try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Majer Sternfeld", "--role", "subject"])[0]

        // A custom (open-vocabulary) type is stored verbatim; a promoted known type
        // folds. Here the promoted `Occupation` carries value "tailor".
        try run(
            MentionFactAddCommand.self,
            [archive, artifact, "--ref", ref, "--type", "Occupation", "--value", "tailor"])

        let fact = try #require(
            engine(archive).artifact(withID: ArtifactID(artifact))?
                .personsMentioned.first { $0.localRef == ref }?.facts.first)
        #expect(fact.type == .occupation)
        #expect(fact.value == "tailor")
        #expect(fact.date == nil)

        // `show` surfaces the value on the mention's fact row.
        let shown = try run(ShowCommand.self, [archive, artifact]).joined(separator: "\n")
        #expect(shown.contains("Occupation"))
        #expect(shown.contains("tailor"))
    }

    /// A parent-child qualifier describes a concluded *edge* between two identities,
    /// so it can't be something a document records about one named person — the
    /// evidence-side mirror of `FactScope`.
    @Test func mentionFactRejectsParentChildQualifiers() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "Register")
        let ref = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Anna"])[0]

        let message = try runExpectingFailure(
            MentionFactAddCommand.self,
            [archive, artifact, "--ref", ref, "--type", "AdoptiveParent"])
        #expect(message.contains("AdoptiveParent"))
        #expect(message.contains("--relationship"))
        // A couple type *is* allowed: a marriage register's entry for the groom
        // genuinely records his marriage.
        try run(
            MentionFactAddCommand.self,
            [archive, artifact, "--ref", ref, "--type", "Marriage", "--date", "1918"])
        // …as is a type nobody enumerated, since open vocabularies must round-trip.
        try run(
            MentionFactAddCommand.self,
            [archive, artifact, "--ref", ref, "--type", "Enumeration"])
    }

    /// The full bridge: record a mention, conclude a person, link them, see the
    /// citation from the person's side, then unlink — which removes *only* the
    /// link, leaving both the evidence and the conclusion standing.
    @Test func linkAndUnlinkResolveAMention() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")
        let ref = try run(
            MentionAddCommand.self,
            [
                archive, artifact, "--name", "Anna Meyer", "--role", "subject",
                "--quality", "primary", "--age", "28",
            ])[0]
        let person = try addPerson(archive, given: "Anna", surname: "Meyer")

        let link = try run(
            LinkCommand.self,
            [
                archive, "--artifact", artifact, "--mention", ref, "--person", person,
                "--reviewed-by", "ada",
            ])[0]
        #expect(link.hasPrefix("LNK-"))

        let stored = try engine(archive).links(for: PersonID(person))
        #expect(stored.count == 1)
        #expect(stored.first?.reviewedBy == "ada")
        #expect(stored.first?.reviewStatus == .humanConfirmed)

        let shown = try run(PersonShowCommand.self, [archive, person]).joined(separator: "\n")
        #expect(shown.contains("1920 Census"))
        #expect(shown.contains("as recorded: \"Anna Meyer\""))

        try run(UnlinkCommand.self, [archive, link])
        let opened = try engine(archive)
        #expect(opened.links(for: PersonID(person)).isEmpty)
        #expect(opened.person(withID: PersonID(person)) != nil, "the conclusion survives")
        #expect(
            opened.artifact(withID: ArtifactID(artifact))?.personsMentioned.count == 1,
            "the evidence survives")
    }

    /// Removing a mention leaves any link that pointed at it dangling (§2.3) and
    /// says so.
    @Test func mentionRmReportsDanglingLinks() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")
        let ref = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Anna Meyer"])[0]
        let person = try addPerson(archive, given: "Anna", surname: "Meyer")
        try run(
            LinkCommand.self,
            [archive, "--artifact", artifact, "--mention", ref, "--person", person])

        let output = try run(
            MentionRemoveCommand.self, [archive, artifact, "--ref", ref]
        ).joined(separator: "\n")
        #expect(output.contains("1 evidence link(s)"))
        #expect(try engine(archive).links(for: PersonID(person)).count == 1)
    }

    /// Removing a mention that isn't there is an error, not a silent no-op.
    @Test func mentionRmRejectsUnknownRef() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")
        let stderr = try runExpectingFailure(
            MentionRemoveCommand.self, [archive, artifact, "--ref", "p9"])
        #expect(stderr.contains("No mention p9"))
    }

    // MARK: - trash

    /// `remove` moves an artifact to the package trash rather than destroying it, and
    /// `trash restore` brings it back uid-faithfully — the headless door onto the
    /// same store the app's Trash sheet opens.
    @Test func artifactRoundTripsThroughTheTrash() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")

        try run(RemoveCommand.self, [archive, artifact])
        #expect(try engine(archive).artifact(withID: ArtifactID(artifact)) == nil)

        let listed = try run(TrashListCommand.self, [archive])
        #expect(listed.count == 1)
        let columns = listed[0].split(separator: "\t", omittingEmptySubsequences: false)
        #expect(columns[0] == "artifact")
        #expect(columns[1] == artifact[...])
        #expect(columns[2] == "1920 Census")

        try run(TrashRestoreCommand.self, [archive, artifact])
        #expect(try engine(archive).artifact(withID: ArtifactID(artifact))?.title == "1920 Census")
        #expect(try run(TrashListCommand.self, [archive]).isEmpty)
    }

    /// A detached file is trash-backed too, and restoring re-attaches it to the
    /// artifact it came from.
    @Test func detachedFileRoundTripsThroughTheTrash() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")
        let source = try TestSupport.makeSourceFile(named: "scan.txt", contents: "bytes")
        let attached = try run(
            AttachCommand.self,
            [
                archive, "--artifact", artifact, "--file", source.path, "--role",
                "preservation-master",
            ])[0]
        let fileUID = String(attached.split(separator: "\t")[0])

        try run(DetachCommand.self, [archive, "--artifact", artifact, "--file", fileUID])
        #expect(try engine(archive).artifact(withID: ArtifactID(artifact))?.files.isEmpty == true)
        #expect(try run(TrashListCommand.self, [archive])[0].hasPrefix("file\t"))

        try run(TrashRestoreCommand.self, [archive, fileUID])
        let files = try engine(archive).artifact(withID: ArtifactID(artifact))?.files
        #expect(files?.count == 1)
        #expect(files?.first?.uid.raw == fileUID, "restored uid-faithfully")
    }

    /// `trash empty` clears both kinds, and reports what it destroyed.
    @Test func trashEmptyClearsBothKinds() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")
        try run(RemoveCommand.self, [archive, artifact])

        let output = try run(TrashEmptyCommand.self, [archive])[0]
        #expect(output.contains("1 artifact(s)"))
        #expect(try run(TrashListCommand.self, [archive]).isEmpty)
    }

    /// `trash restore`/`remove` dispatch on the uid's type prefix, so a uid of the
    /// wrong kind is refused rather than looked up in the wrong store.
    @Test func trashRejectsAUidThatIsNotAnArtifactOrFile() throws {
        let archive = try makeArchive()
        let stderr = try runExpectingFailure(TrashRestoreCommand.self, [archive, "PER-whatever"])
        #expect(stderr.contains("isn't a trashed record's uid"))
    }

    // MARK: - Review regressions (slice 44b /code-review)

    /// A freed `localRef` is reused — **unless** a link still claims it. Reusing
    /// one that a dangling link points at would silently re-bind that link to a
    /// different person: a visible dangle turning into an invisible wrong
    /// conclusion. (The two halves of this were each tested separately before;
    /// nothing composed them, which is how the hole survived.)
    @Test func mentionLocalRefIsNotReusedWhileALinkStillClaimsIt() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")

        let ref = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Anna Meyer"])[0]
        let link = try run(
            LinkCommand.self,
            [archive, "--artifact", artifact, "--mention", ref, "--person", anna])[0]

        // Remove the mention; the link survives, still naming `p1` (§2.3).
        try run(MentionRemoveCommand.self, [archive, artifact, "--ref", ref])

        let next = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Otto Schmidt"])[0]
        #expect(next != ref, "a claimed ref must not be handed out again")

        // Anna's citation must not now read "Otto Schmidt".
        let shown = try run(PersonShowCommand.self, [archive, anna]).joined(separator: "\n")
        #expect(shown.contains(link))
        #expect(!shown.contains("Otto Schmidt"))
    }

    /// `trash remove` destroys bytes irreversibly, and the engine is *lenient* about a
    /// uid that isn't there — so the command must check, or it reports a deletion
    /// that never happened and the entry dies later at `trash empty` instead.
    @Test func trashRmRejectsAUidNotInTheTrash() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")

        let stderr = try runExpectingFailure(
            TrashRemoveCommand.self, [archive, "ART-019f0000-0000-7000-8000-000000000000"])
        #expect(stderr.contains("isn't in the trash"))

        // The real entry is untouched and still restorable.
        try run(RemoveCommand.self, [archive, artifact])
        try run(TrashRemoveCommand.self, [archive, artifact])
        #expect(try run(TrashListCommand.self, [archive]).isEmpty)
    }

    /// The five parent-child qualifiers are mutually-exclusive answers to one
    /// question, so recording one **replaces** any existing one. Appending would
    /// let a link assert two natures at once — a state the app can't produce and
    /// silently drops on the next edit.
    @Test func parentChildQualifierReplacesRatherThanAccumulates() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let ella = try addPerson(archive, given: "Ella", surname: "Meyer")
        let rel = try run(
            RelateCommand.self,
            [archive, "--parent", anna, "--child", ella, "--nature", "BiologicalParent"])[0]

        try run(
            FactAddCommand.self, [archive, "--relationship", rel, "--type", "AdoptiveParent"])
        try run(FactAddCommand.self, [archive, "--relationship", rel, "--type", "StepParent"])

        let facts = try engine(archive).relationship(withID: RelationshipID(rel))?.facts
        #expect(facts?.map(\.type) == [.stepParent])
    }

    /// A couple fact on the same relationship coexists with a qualifier — only
    /// *qualifiers* replace each other, not every fact.
    @Test func replacingAQualifierLeavesOtherFactsAlone() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")
        let otto = try addPerson(archive, given: "Otto", surname: "Meyer")
        let rel = try run(RelateCommand.self, [archive, "--partner", anna, "--partner", otto])[0]

        try run(
            FactAddCommand.self,
            [archive, "--relationship", rel, "--type", "Marriage", "--date", "1912"])
        try run(
            FactAddCommand.self,
            [archive, "--relationship", rel, "--type", "Divorce", "--date", "1920"])

        let facts = try engine(archive).relationship(withID: RelationshipID(rel))?.facts
        #expect(facts?.map(\.type) == [.marriage, .divorce])
    }

    /// Nothing downstream stops a person being their own parent or spouse — the
    /// engine only checks the endpoints *exist* — so the command has to.
    @Test func relateRejectsSelfRelationship() throws {
        let archive = try makeArchive()
        let anna = try addPerson(archive, given: "Anna", surname: "Meyer")

        #expect(
            try runExpectingFailure(
                RelateCommand.self, [archive, "--partner", anna, "--partner", anna]
            )
            .contains("related to themselves"))
        #expect(
            try runExpectingFailure(
                RelateCommand.self, [archive, "--parent", anna, "--child", anna]
            )
            .contains("related to themselves"))
        #expect(try engine(archive).relationships().isEmpty)
    }

    /// An unrecognized vocabulary value is stored **trimmed**, so shell quoting
    /// can't mint `.unknown("  X  ")` beside a later `.unknown("X")` — the same
    /// twin-value drift the case-fold exists to prevent.
    @Test func unknownVocabularyValueIsStoredTrimmed() throws {
        let archive = try makeArchive()
        let uid = try addPerson(archive, given: "Anna", surname: "Meyer")

        try run(FactAddCommand.self, [archive, "--person", uid, "--type", "  Enumeration  "])

        #expect(
            try engine(archive).person(withID: PersonID(uid))?.facts.map(\.type)
                == [.unknown("Enumeration")])
    }

    /// `mention list` prints the refs `link` takes.
    @Test func mentionLsListsRefsNamesAndRoles() throws {
        let archive = try makeArchive()
        let artifact = try addArtifact(archive, title: "1920 Census")
        try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Anna Meyer", "--role", "subject"])
        try run(
            MentionAddCommand.self,
            [archive, artifact, "--name", "Otto Meyer", "--role", "spouse"])

        #expect(
            try run(MentionListCommand.self, [archive, artifact])
                == ["p1\tAnna Meyer\tsubject", "p2\tOtto Meyer\tspouse"])
    }

    // MARK: - person merge (slice 45f)

    /// The cascade, headless: the surviving record keeps the absorbed one's names and
    /// facts, and the link that named the duplicate now names the survivor rather than
    /// dangling the way every other removal in this CLI leaves things.
    @Test func personMergeRepointsEvidenceAndUnionsTheRecords() throws {
        let archive = try makeArchive()
        let survivor = try addPerson(archive, given: "Marcus", surname: "Hanner")
        let absorbed = try addPerson(archive, given: "Meir", surname: "Hanner")
        let artifact = try addArtifact(archive, title: "1899 Marriage Register")
        let ref = try run(
            MentionAddCommand.self, [archive, artifact, "--name", "Meir Hanner"])[0]
        try run(
            LinkCommand.self,
            [archive, "--artifact", artifact, "--mention", ref, "--person", absorbed])

        let output = try run(
            PersonMergeCommand.self, [archive, absorbed, "--into", survivor]
        ).joined(separator: "\n")

        #expect(output.contains("Merged \(absorbed) into \(survivor)"))
        #expect(output.contains("1 name(s)"))
        #expect(output.contains("Repointed: 1 evidence link(s)"))

        let opened = try engine(archive)
        #expect(opened.person(withID: PersonID(absorbed)) == nil)
        #expect(opened.links(for: PersonID(survivor)).count == 1)
        #expect(opened.findDanglingReferences().isEmpty)
    }

    /// A dropped record is **named**, not counted — it no longer exists, so a bare
    /// number is nothing the user can go and look at. Both drop reasons say which one
    /// they were.
    @Test func personMergeNamesWhatItDropped() throws {
        let archive = try makeArchive()
        let survivor = try addPerson(archive, given: "Marcus", surname: "Hanner")
        let absorbed = try addPerson(archive, given: "Meir", surname: "Hanner")
        let relationship = try run(
            RelateCommand.self, [archive, "--partner", survivor, "--partner", absorbed])[0]

        let output = try run(
            PersonMergeCommand.self, [archive, absorbed, "--into", survivor]
        ).joined(separator: "\n")

        #expect(output.contains("Dropped relationship \(relationship)"))
        #expect(output.contains("related the two merged persons to each other"))
        #expect(try engine(archive).relationships(of: PersonID(survivor)).isEmpty)
    }

    /// Merging a person into themselves would delete the survivor. The engine guards it;
    /// this pins that the CLI surfaces the refusal rather than exiting 0 on a no-op.
    @Test func personMergeRefusesToMergeAPersonIntoItself() throws {
        let archive = try makeArchive()
        let person = try addPerson(archive, given: "Marcus", surname: "Hanner")

        let message = try runExpectingFailure(
            PersonMergeCommand.self, [archive, person, "--into", person])

        #expect(message.contains("into itself"))
        #expect(try engine(archive).person(withID: PersonID(person)) != nil)
    }

    // MARK: - Shared helpers

    private func addArtifact(_ archive: String, title: String) throws -> String {
        try run(AddCommand.self, [archive, "--title", title])[0]
    }
}
