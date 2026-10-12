import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// Coverage of the Phase-3 slice-44d evidence-layer + read-surface commands:
/// `event`/`place`, the artifact `show` register, `set-role`/`replace-file`, the
/// `set-meta` additions, the `find` facets, the `lookup` point lookups,
/// `relationship list`, and `verify`'s informational dangling-reference sweep.
///
/// Driven exactly like `ConclusionsCommandTests` (parse argv → run against a temp
/// archive → assert on captured stdout **and** on real on-disk engine state), and
/// like it, this is the second, assumption-free consumer of the settled API.
@Suite struct EvidenceCommandTests {

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

    private func makeArchive(named name: String = "Evidence") throws -> String {
        let root = TestSupport.makeTempDirectory(function: "\(name)-\(UUID().uuidString)")
        let path = root.appendingPathComponent(name).path
        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        return path
    }

    private func engine(_ path: String) throws -> Archive {
        try Archive.open(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func addArtifact(_ archive: String, title: String = "Census") throws -> String {
        try run(
            AddCommand.self,
            [archive, "--title", title, "--media-type", "image", "--source-tier", "census"])[0]
    }

    /// Attaches a file with the given contents and returns its `FIL-` uid.
    private func attach(_ archive: String, to artifact: String, contents: String = "hello") throws
        -> String
    {
        let source = try TestSupport.makeSourceFile(named: "scan.txt", contents: contents)
        let line = try run(
            AttachCommand.self, [archive, "--artifact", artifact, "--file", source.path])[0]
        return line.split(separator: "\t").map(String.init)[0]
    }

    // MARK: - event

    /// `event add` stores an `Event`, normalizing a shorthand date to canonical
    /// EDTF, and prints the minted index; `show` renders it back with its gloss.
    @Test func eventAddNormalizesDateAndShows() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)

        let added = try run(
            EventAddCommand.self,
            [archive, art, "--type", "Census", "--date", "June 1920", "--location", "Cook County"])
        #expect(added[0].hasPrefix("0\t"))

        let stored = try engine(archive).artifact(withID: ArtifactID(art))?.events
        #expect(stored?.count == 1)
        #expect(stored?.first?.type == "Census")
        #expect(stored?.first?.date == "1920-06")  // "June 1920" → canonical EDTF
        #expect(stored?.first?.location == "Cook County")

        let shown = try run(ShowCommand.self, [archive, art])
        #expect(shown.contains { $0.contains("[0] Census") && $0.contains("1920-06") })
    }

    /// `event remove` drops by index; an out-of-range index is a clean error
    /// (pointing at `genea show`), and leaves the record untouched.
    @Test func eventRemoveByIndexAndOutOfRange() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        try run(EventAddCommand.self, [archive, art, "--type", "Census"])
        try run(EventAddCommand.self, [archive, art, "--type", "Birth"])

        try run(EventRemoveCommand.self, [archive, art, "--index", "0"])
        let remaining = try engine(archive).artifact(withID: ArtifactID(art))?.events
        #expect(remaining?.map(\.type) == ["Birth"])

        let error = try runExpectingFailure(
            EventRemoveCommand.self, [archive, art, "--index", "9"])
        #expect(error.contains("No event at index 9"))
        #expect(error.contains("genea show"))
        #expect(try engine(archive).artifact(withID: ArtifactID(art))?.events.count == 1)
    }

    // MARK: - place

    @Test func placeAddAndRemove() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)

        let added = try run(
            PlaceAddCommand.self,
            [archive, art, "--as-recorded", "Cook Co.", "--normalized", "Cook County, Illinois"])
        #expect(added[0].hasPrefix("0\t"))
        let stored = try engine(archive).artifact(withID: ArtifactID(art))?.locations
        #expect(stored?.first?.asRecorded == "Cook Co.")
        #expect(stored?.first?.normalized == "Cook County, Illinois")

        try run(PlaceRemoveCommand.self, [archive, art, "--index", "0"])
        #expect(try engine(archive).artifact(withID: ArtifactID(art))?.locations.isEmpty == true)
    }

    // MARK: - show

    /// `show` renders each section with the right indices, and the descriptive
    /// fields it was given.
    @Test func showRendersSections() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive, title: "1920 Census")
        try run(EventAddCommand.self, [archive, art, "--type", "Census", "--date", "1920"])
        try run(PlaceAddCommand.self, [archive, art, "--as-recorded", "Chicago"])
        try run(
            MentionAddCommand.self, [archive, art, "--name", "Anna Meyer", "--role", "subject"])
        _ = try attach(archive, to: art)

        let out = try run(ShowCommand.self, [archive, art])
        let text = out.joined(separator: "\n")
        #expect(out[0].hasPrefix(art) && out[0].contains("1920 Census"))
        #expect(text.contains("Events:") && text.contains("[0] Census"))
        #expect(text.contains("Places:") && text.contains("[0] Chicago"))
        #expect(text.contains("Persons Mentioned:") && text.contains("Anna Meyer"))
        #expect(text.contains("Files:") && text.contains("FIL-"))
    }

    // MARK: - set-role / replace-file

    @Test func setRoleChangesAndReportsPrior() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let file = try attach(archive, to: art)  // defaults to preservation-master

        let out = try run(
            SetRoleCommand.self,
            [archive, "--artifact", art, "--file", file, "--role", "access-copy"])
        #expect(out[0].contains("was preservation-master"))
        let role = try engine(archive).artifact(withID: ArtifactID(art))?.files.first?.role
        #expect(role == .accessCopy)

        // A no-op change reports "unchanged" and doesn't pretend it swapped.
        let again = try run(
            SetRoleCommand.self,
            [archive, "--artifact", art, "--file", file, "--role", "access-copy"])
        #expect(again[0].contains("already has role access-copy"))
    }

    @Test func replaceFileSwapsContent() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let file = try attach(archive, to: art, contents: "v1")
        let before = try engine(archive).artifact(withID: ArtifactID(art))?.files.first?.sha256

        let replacement = try TestSupport.makeSourceFile(
            named: "v2.txt", contents: "a much longer version two")
        try run(
            ReplaceFileCommand.self,
            [archive, "--artifact", art, "--file", file, "--with", replacement.path])

        let after = try engine(archive).artifact(withID: ArtifactID(art))?.files.first
        #expect(after?.uid.raw == file)  // uid stable
        #expect(after?.sha256 != before)  // content changed
        #expect(after?.byteLength == 25)
    }

    // MARK: - set-meta additions

    @Test func setMetaLanguageAndOriginalFormat() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        try run(
            SetMetaCommand.self,
            [
                archive, "--artifact", art, "--language", "de-DE", "--original-format",
                "digital scan",
            ])
        let record = try engine(archive).artifact(withID: ArtifactID(art))
        #expect(record?.language == "de-DE")
        #expect(record?.originalFormat == "digital scan")
    }

    @Test func setMetaExternalIdReplaceAndClear() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        try run(
            SetMetaCommand.self,
            [
                archive, "--artifact", art, "--external-id", "ark=12345/abc", "--external-id",
                "doi=10.1/x",
            ])
        var ids = try engine(archive).artifact(withID: ArtifactID(art))?.externalIdentifiers
        #expect(ids?.count == 2)
        #expect(ids?.first?.value == "12345/abc")

        try run(SetMetaCommand.self, [archive, "--artifact", art, "--clear-external-ids"])
        ids = try engine(archive).artifact(withID: ArtifactID(art))?.externalIdentifiers
        #expect(ids?.isEmpty == true)

        // A malformed token (no `=`) is rejected.
        let error = try runExpectingFailure(
            SetMetaCommand.self, [archive, "--artifact", art, "--external-id", "notpair"])
        #expect(error.contains("scheme=value"))
    }

    @Test func setMetaRetrievalRequiresBothThenClears() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)

        // Only one of source/date is a usage error.
        let error = try runExpectingFailure(
            SetMetaCommand.self, [archive, "--artifact", art, "--retrieval-source", "FamilySearch"])
        #expect(error.contains("must be given together"))

        try run(
            SetMetaCommand.self,
            [
                archive, "--artifact", art, "--retrieval-source", "FamilySearch",
                "--retrieval-date", "2026-07-21", "--retrieval-checksum", "abc",
            ])
        var retrieval = try engine(archive).artifact(withID: ArtifactID(art))?.retrieval
        #expect(retrieval?.source == "FamilySearch")
        #expect(retrieval?.date == "2026-07-21")
        #expect(retrieval?.checksum == "abc")

        try run(SetMetaCommand.self, [archive, "--artifact", art, "--clear-retrieval"])
        retrieval = try engine(archive).artifact(withID: ArtifactID(art))?.retrieval
        #expect(retrieval == nil)
    }

    // MARK: - find facets

    @Test func findFacets() throws {
        let archive = try makeArchive()
        let a = try run(
            AddCommand.self,
            [
                archive, "--title", "Census A", "--media-type", "image", "--source-tier", "census",
                "--tag", "illinois",
            ])[0]
        _ = try run(
            AddCommand.self,
            [archive, "--title", "Deed B", "--media-type", "text", "--source-tier", "vital"])[0]
        try run(EventAddCommand.self, [archive, a, "--type", "Census", "--date", "1920"])

        // free text + tag AND together (both must match A).
        #expect(try run(FindCommand.self, [archive, "Census", "--tag", "illinois"]).count == 1)
        #expect(try run(FindCommand.self, [archive, "Census", "--tag", "nope"]).isEmpty)

        // source tier facet.
        let censusHits = try run(FindCommand.self, [archive, "--source-tier", "census"])
        #expect(censusHits.count == 1 && censusHits[0].contains(a))

        // year range (one-sided and two-sided) hits the artifact with a 1920 event.
        #expect(try run(FindCommand.self, [archive, "--from-year", "1919"]).count == 1)
        #expect(
            try run(FindCommand.self, [archive, "--from-year", "1900", "--to-year", "1910"]).isEmpty
        )

        // no criterion → usage error.
        let error = try runExpectingFailure(FindCommand.self, [archive])
        #expect(error.contains("at least one facet"))

        // a reversed year pair is a clean usage error, not a range-constructor
        // fatal error (`from > to` would trap `lower...upper`).
        let reversed = try runExpectingFailure(
            FindCommand.self, [archive, "--from-year", "2000", "--to-year", "1900"])
        #expect(reversed.contains("on or before"))
    }

    @Test func findMentioning() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        try run(MentionAddCommand.self, [archive, art, "--name", "Anna Meyer"])
        #expect(try run(FindCommand.self, [archive, "--mentioning", "meyer"]).count == 1)
        #expect(try run(FindCommand.self, [archive, "--mentioning", "schmidt"]).isEmpty)
    }

    // MARK: - lookup

    @Test func lookupModes() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let file = try attach(archive, to: art, contents: "dedup-me")
        try run(SetMetaCommand.self, [archive, "--artifact", art, "--external-id", "ark=abc/1"])
        let ref = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]
        let anna = try run(PersonAddCommand.self, [archive, "--given", "Anna"])[0]
        try run(
            LinkCommand.self,
            [archive, "--artifact", art, "--mention", ref, "--person", anna])

        // external-id → the one artifact carrying it.
        let byExternal = try run(LookupCommand.self, [archive, "--external-id", "ark=abc/1"])
        #expect(byExternal.count == 1 && byExternal[0].contains(art))

        // sha256 → the artifact owning the file (the dedup check).
        let sha =
            try engine(archive).artifact(withID: ArtifactID(art))?.files
            .first(where: { $0.uid.raw == file })?.sha256 ?? ""
        let bySha = try run(LookupCommand.self, [archive, "--sha256", sha])
        #expect(bySha.count == 1 && bySha[0].contains(art))

        // mentions PER → conclusions-aware (follows the link).
        let byPerson = try run(LookupCommand.self, [archive, "--mentions", anna])
        #expect(byPerson.count == 1 && byPerson[0].contains(art))

        // at-path → the artifact whose folder/file matches.
        let slug = try #require(
            engine(archive).artifacts().first(where: { $0.uid.raw == art })?.slug)
        let byPath = try run(LookupCommand.self, [archive, "--at-path", "artifacts/\(slug)"])
        #expect(byPath.count == 1 && byPath[0].contains(art))

        // exactly one mode required.
        let error = try runExpectingFailure(
            LookupCommand.self, [archive, "--at-path", "x", "--sha256", "y"])
        #expect(error.contains("exactly one"))
    }

    // MARK: - relationship list

    @Test func relationshipList() throws {
        let archive = try makeArchive()
        let anna = try run(PersonAddCommand.self, [archive, "--given", "Anna"])[0]
        let otto = try run(PersonAddCommand.self, [archive, "--given", "Otto"])[0]
        let rel = try run(
            RelateCommand.self, [archive, "--partner", anna, "--partner", otto])[0]

        let listed = try run(RelationshipListCommand.self, [archive])
        #expect(listed.count == 1)
        let parts = listed[0].split(separator: "\t").map(String.init)
        #expect(parts[0] == rel)
        #expect(parts[1] == "couple")
        #expect(Set([parts[2], parts[3]]) == Set([anna, otto]))
    }

    // MARK: - verify: dangling references (informational) vs file corruption (fatal)

    /// A dangling reference (a person removed while a link/relationship still
    /// names them) is **printed but never trips the exit** — `run` returns
    /// without throwing.
    @Test func verifySurfacesDanglingButExitsZero() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let ref = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]
        let anna = try run(PersonAddCommand.self, [archive, "--given", "Anna"])[0]
        try run(
            LinkCommand.self, [archive, "--artifact", art, "--mention", ref, "--person", anna])
        try run(PersonRemoveCommand.self, [archive, anna])  // leaves the link dangling

        // Does NOT throw — dangling refs are informational.
        let out = try run(VerifyCommand.self, [archive])
        let text = out.joined(separator: "\n")
        #expect(text.contains("Dangling references"))
        #expect(text.contains("link-person"))
        #expect(text.contains("1 dangling reference(s)"))
    }

    /// A real file-integrity problem (out-of-band content edit) still exits
    /// non-zero, the load-bearing CI contract.
    @Test func verifyFileCorruptionExitsNonZero() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let file = try attach(archive, to: art, contents: "original")

        // Corrupt the file's bytes on disk, behind the manifest's back.
        let fileURL = try #require(
            engine(archive).fileURL(of: FileID(file), in: ArtifactID(art)))
        try "tampered-and-longer".write(to: fileURL, atomically: true, encoding: .utf8)

        let error = try runExpectingFailure(VerifyCommand.self, [archive])
        // The thrown `ExitCode` carries no message, so nothing lands on stderr;
        // the assertion is simply that it threw (runExpectingFailure enforces it).
        _ = error
    }

    // MARK: - slice 44h: source derivation, name tags, and the show register

    /// The GPS derivation axis (slice 44h): settable at `add`, changeable and
    /// **clearable** at `set-meta`. Clearable matters because absent means *unstated*
    /// — without a clear flag, a value set once could never be taken back, and
    /// "unstated" would become unreachable.
    @Test func sourceDerivationIsSettableChangeableAndClearable() throws {
        let archive = try makeArchive()
        let art = try run(
            AddCommand.self,
            [
                archive, "--title", "Parish register p.14", "--source-tier", "church",
                "--source-derivation", "original",
            ])[0]
        #expect(
            try engine(archive).artifact(withID: ArtifactID(art))?.sourceDerivation == .original)

        // It shows in the register only when stated — see the clear case below.
        let shown = try run(ShowCommand.self, [archive, art]).joined(separator: "\n")
        #expect(shown.contains("source derivation: original"))

        try run(
            SetMetaCommand.self, [archive, "--artifact", art, "--source-derivation", "derivative"])
        #expect(
            try engine(archive).artifact(withID: ArtifactID(art))?.sourceDerivation == .derivative)

        try run(SetMetaCommand.self, [archive, "--artifact", art, "--clear-source-derivation"])
        #expect(try engine(archive).artifact(withID: ArtifactID(art))?.sourceDerivation == nil)
        let cleared = try run(ShowCommand.self, [archive, art]).joined(separator: "\n")
        #expect(!cleared.contains("source derivation"))

        // Open vocabulary: a derivation nobody enumerated round-trips verbatim.
        try run(
            SetMetaCommand.self, [archive, "--artifact", art, "--source-derivation", "microfilm"])
        #expect(
            try engine(archive).artifact(withID: ArtifactID(art))?.sourceDerivation
                == .unknown("microfilm"))
    }

    /// An artifact created before 44h has no derivation, and absence must stay
    /// absence — never defaulted to `original`, which would assert the strongest
    /// reading of a source on the researcher's behalf.
    @Test func sourceDerivationDefaultsToUnstatedNotOriginal() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        #expect(try engine(archive).artifact(withID: ArtifactID(art))?.sourceDerivation == nil)
    }

    /// Name language/script on both layers: `nameAsRecorded` (evidence) and
    /// `PersonName` (conclusions). Orthogonal tags — a transliterated Russian name
    /// is language `ru`, script `Latn` — which is what lets a matcher choose a
    /// phonetic algorithm rather than keying Cyrillic with Latin phonetics.
    @Test func nameLanguageAndScriptAreRecordedOnBothLayers() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive, title: "Metrical register")

        let ref = try run(
            MentionAddCommand.self,
            [
                archive, art, "--name", "Мотек Штернфельд", "--role", "subject",
                "--name-language", "ru", "--name-script", "Cyrl",
            ])[0]
        let mention = try engine(archive).artifact(withID: ArtifactID(art))?
            .personsMentioned.first { $0.localRef == ref }
        #expect(mention?.nameLanguage == "ru")
        #expect(mention?.nameScript == "Cyrl")
        #expect(try run(ShowCommand.self, [archive, art]).joined().contains("ru/Cyrl"))

        let person = try run(
            PersonAddCommand.self,
            [
                archive, "--given", "Анна", "--surname", "Штернфельд",
                "--language", "ru", "--script", "Cyrl",
            ])[0]
        // A second name for the same person, transliterated: same language, new script.
        try run(
            PersonNameAddCommand.self,
            [
                archive, person, "--given", "Anna", "--surname", "Sternfeld",
                "--name-type", "also-known-as", "--language", "ru", "--script", "Latn",
            ])
        let names = try #require(engine(archive).person(withID: PersonID(person))?.names)
        #expect(names.map(\.script) == ["Cyrl", "Latn"])
        #expect(names.allSatisfy { $0.language == "ru" })
        // …and `person name set` can retag an existing name.
        try run(PersonNameSetCommand.self, [archive, person, "--index", "0", "--script", "Hebr"])
        #expect(
            try engine(archive).person(withID: PersonID(person))?.names.first?.script == "Hebr")
    }

    /// `show` nests a mention's recorded facts under it with the indices
    /// `mention fact remove` takes — the register saying which of the people it
    /// names each date belongs to, which is the whole point of scoping them.
    @Test func showNestsRecordedFactsUnderTheirMention() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive, title: "Household")
        let head = try run(MentionAddCommand.self, [archive, art, "--name", "Majer"])[0]
        try run(
            MentionFactAddCommand.self,
            [archive, art, "--ref", head, "--type", "Birth", "--date", "1892", "--place", "Łomża"])

        let lines = try run(ShowCommand.self, [archive, art])
        let mentionLine = try #require(lines.firstIndex { $0.contains("Majer") })
        let factLine = lines[mentionLine + 1]
        #expect(factLine.contains("[0]"))
        #expect(factLine.contains("Birth"))
        #expect(factLine.contains("Łomża"))
        // Indented deeper than the mention it belongs to.
        #expect(factLine.hasPrefix("    "))
    }

    /// A name carrying only one of the two tags must not render a dangling separator,
    /// and both formatters must agree on what "absent" means — they were written in
    /// one slice and had already drifted to two different emptiness rules.
    @Test func languageScriptTagRendersConsistentlyOnBothLayers() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)

        // Language only, on the evidence side.
        let ref = try run(
            MentionAddCommand.self,
            [archive, art, "--name", "Anna", "--name-language", "pl"])[0]
        let shown = try run(ShowCommand.self, [archive, art]).joined(separator: "\n")
        #expect(shown.contains("pl"))
        #expect(!shown.contains("pl/"))
        _ = ref

        // Script only, on the conclusions side — the mirror case.
        let person = try run(
            PersonAddCommand.self, [archive, "--given", "Anna", "--script", "Latn"])[0]
        let personShown = try run(PersonShowCommand.self, [archive, person])
            .joined(separator: "\n")
        #expect(personShown.contains("[Latn]"))
        #expect(!personShown.contains("/Latn"))
    }

    /// Removing a mention destroys the facts scoped to it, and the CLI has no undo —
    /// so the command says what it cost, the same discipline it already applies to
    /// the links it leaves dangling.
    @Test func mentionRemoveReportsTheRecordedFactsItDestroys() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let ref = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]
        try run(
            MentionFactAddCommand.self,
            [archive, art, "--ref", ref, "--type", "Birth", "--date", "1892"])
        try run(
            MentionFactAddCommand.self,
            [archive, art, "--ref", ref, "--type", "Death", "--date", "1948"])

        let out = try run(MentionRemoveCommand.self, [archive, art, "--ref", ref])
            .joined(separator: "\n")
        #expect(out.contains("2 recorded fact(s)"))

        // A mention with no facts says nothing extra — the report is about real cost.
        let bare = try run(MentionAddCommand.self, [archive, art, "--name", "Otto"])[0]
        let bareOut = try run(MentionRemoveCommand.self, [archive, art, "--ref", bare])
            .joined(separator: "\n")
        #expect(!bareOut.contains("recorded fact"))
    }

    // MARK: - Stated relationships (slice 45k)

    /// The Sidney death certificate, headlessly: state both parent edges, and `show`
    /// renders them with the names the refs stand for. This is the hand-test's path.
    @Test func mentionRelateStatesAnEdgeThatShowRendersWithNames() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive, title: "Sidney Feldberg death certificate")
        let sidney = try run(MentionAddCommand.self, [archive, art, "--name", "Sidney Feldberg"])[0]
        let father = try run(
            MentionAddCommand.self,
            [archive, art, "--name", "Marcus Feldberg", "--role", "parent"])[0]
        let mother = try run(
            MentionAddCommand.self,
            [archive, art, "--name", "Sarah Hanner", "--role", "parent"])[0]

        // §4.5's direction: ref1 is the parent.
        let minted = try run(
            MentionRelateAddCommand.self, [archive, art, "--ref1", father, "--ref2", sidney])
        #expect(minted[0].hasPrefix("0\t"))
        try run(MentionRelateAddCommand.self, [archive, art, "--ref1", mother, "--ref2", sidney])
        try run(
            MentionRelateAddCommand.self,
            [archive, art, "--ref1", father, "--ref2", mother, "--type", "couple"])

        let stored = try #require(engine(archive).artifact(withID: ArtifactID(art)))
        #expect(stored.mentionRelationships.count == 3)
        #expect(stored.mentionRelationships[0].parentRef == father)
        #expect(stored.mentionRelationships[0].childRef == sidney)

        let shown = try run(ShowCommand.self, [archive, art])
        let section = try #require(shown.firstIndex { $0 == "Relationships Stated:" })
        #expect(shown[section + 1].contains("[0]"))
        #expect(shown[section + 1].contains("parent-child"))
        #expect(shown[section + 1].contains("Marcus Feldberg → Sidney Feldberg"))
        #expect(shown[section + 3].contains("couple"))
    }

    /// A record that states nothing gets no empty section — silence is the norm (§6.1),
    /// and a "(none)" line on every artifact in the archive is noise.
    @Test func showOmitsTheRelationshipsSectionWhenNoneAreStated() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])
        #expect(!(try run(ShowCommand.self, [archive, art]).contains("Relationships Stated:")))
    }

    /// The CLI refuses to *author* an edge that dangles on arrival, or one the record
    /// already states, or a mention related to itself. (A removal may still strand one
    /// — that is §2.3, and `verify` is what finds it.)
    @Test func mentionRelateRefusesRefusableEdges() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let anna = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]

        #expect(
            try runExpectingFailure(
                MentionRelateAddCommand.self, [archive, art, "--ref1", anna, "--ref2", "p9"]
            ).contains("No mention p9"))
        #expect(
            try runExpectingFailure(
                MentionRelateAddCommand.self, [archive, art, "--ref1", anna, "--ref2", anna]
            ).contains("cannot be related to itself"))

        let otto = try run(MentionAddCommand.self, [archive, art, "--name", "Otto"])[0]
        try run(MentionRelateAddCommand.self, [archive, art, "--ref1", otto, "--ref2", anna])
        #expect(
            try runExpectingFailure(
                MentionRelateAddCommand.self, [archive, art, "--ref1", otto, "--ref2", anna]
            ).contains("already states that relationship"))

        // A `couple` is symmetric, so the reverse pair is the *same* entry — the case an
        // equality check misses (§6.1). The reversed `parent-child` beside it is not a
        // duplicate but a contradiction, and is accepted: the format doesn't adjudicate.
        try run(
            MentionRelateAddCommand.self,
            [archive, art, "--ref1", otto, "--ref2", anna, "--type", "couple"])
        #expect(
            try runExpectingFailure(
                MentionRelateAddCommand.self,
                [archive, art, "--ref1", anna, "--ref2", otto, "--type", "couple"]
            ).contains("already states that relationship"))
        try run(MentionRelateAddCommand.self, [archive, art, "--ref1", anna, "--ref2", otto])
        #expect(
            try engine(archive).artifact(withID: ArtifactID(art))?.mentionRelationships.count == 3)
    }

    /// **A rejected command must not write.** `updateMetadata` commits whatever its
    /// closure leaves behind, so validating inside it meant a refused add still rewrote
    /// `record.json`, re-upserted the index and committed the manifest. Asserted on the
    /// file's modification time, since the record's *content* is identical either way —
    /// which is exactly why the original slipped through.
    @Test func aRejectedRelateLeavesTheRecordUnwritten() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let anna = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]
        let otto = try run(MentionAddCommand.self, [archive, art, "--name", "Otto"])[0]
        try run(MentionRelateAddCommand.self, [archive, art, "--ref1", otto, "--ref2", anna])

        let slug = try #require(engine(archive).artifacts().first).slug
        let record = URL(fileURLWithPath: archive)
            .appendingPathComponent("artifacts").appendingPathComponent(slug)
            .appendingPathComponent("record.json")
        func writtenAt() throws -> Date {
            try #require(
                FileManager.default.attributesOfItem(atPath: record.path)[.modificationDate]
                    as? Date)
        }

        let before = try writtenAt()
        // Long enough that a write would move the timestamp on any filesystem.
        Thread.sleep(forTimeInterval: 1.1)

        _ = try? runExpectingFailure(
            MentionRelateAddCommand.self, [archive, art, "--ref1", anna, "--ref2", "p9"])
        _ = try? runExpectingFailure(
            MentionRelateAddCommand.self, [archive, art, "--ref1", otto, "--ref2", anna])
        _ = try? runExpectingFailure(
            MentionRelateRemoveCommand.self, [archive, art, "--index", "7"])

        #expect(try writtenAt() == before, "a refused command rewrote the record")
    }

    /// Removing an edge is by the index `show` prints, and an out-of-range index is a
    /// user error rather than a crash — the `mention fact remove` contract.
    @Test func mentionRelateRemovesByIndex() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let anna = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]
        let otto = try run(MentionAddCommand.self, [archive, art, "--name", "Otto"])[0]
        try run(MentionRelateAddCommand.self, [archive, art, "--ref1", otto, "--ref2", anna])

        #expect(
            try runExpectingFailure(
                MentionRelateRemoveCommand.self, [archive, art, "--index", "3"]
            ).contains("No stated relationship at index 3"))
        let out = try run(MentionRelateRemoveCommand.self, [archive, art, "--index", "0"])
            .joined()
        #expect(out.contains("parent-child"))
        #expect(
            try engine(archive).artifact(withID: ArtifactID(art))?.mentionRelationships.isEmpty
                == true)
    }

    /// Removing a mention leaves the edges that named it (§2.3, no cascade), so the
    /// command says so at the moment it happens — the same discipline it applies to
    /// the links and the facts.
    @Test func mentionRemoveReportsTheEdgesItStrands() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let anna = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]
        let otto = try run(MentionAddCommand.self, [archive, art, "--name", "Otto"])[0]
        try run(MentionRelateAddCommand.self, [archive, art, "--ref1", otto, "--ref2", anna])

        let out = try run(MentionRemoveCommand.self, [archive, art, "--ref", otto])
            .joined(separator: "\n")
        #expect(out.contains("1 stated relationship(s)"))
        // Left behind, not cascaded — and `show` marks the end that is gone.
        let stored = try #require(engine(archive).artifact(withID: ArtifactID(art)))
        #expect(stored.mentionRelationships.count == 1)
        #expect(
            try run(ShowCommand.self, [archive, art]).joined(separator: "\n")
                .contains("? → Anna"))
    }

    /// A ref an edge still names is not free, even after its mention is gone: handing
    /// it to the next mention would make a stranger somebody's parent, invisibly.
    @Test func mentionAddSkipsARefAStatedEdgeStillNames() throws {
        let archive = try makeArchive()
        let art = try addArtifact(archive)
        let anna = try run(MentionAddCommand.self, [archive, art, "--name", "Anna"])[0]  // p1
        let otto = try run(MentionAddCommand.self, [archive, art, "--name", "Otto"])[0]  // p2
        try run(MentionRelateAddCommand.self, [archive, art, "--ref1", otto, "--ref2", anna])
        try run(MentionRemoveCommand.self, [archive, art, "--ref", otto])

        let minted = try run(MentionAddCommand.self, [archive, art, "--name", "Stranger"])[0]
        #expect(minted != otto, "p2 is still named by the edge that outlived its mention")
        #expect(minted == "p3")
    }
}
