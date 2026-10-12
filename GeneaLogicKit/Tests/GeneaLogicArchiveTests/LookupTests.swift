import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// The read surface (`Archive+Lookup.swift`, ARCHITECTURE.md §5.1, §6.3).
@Suite struct LookupTests {

    // MARK: - Artifact lookups

    @Test func artifactWithIDFindsAndMissesCorrectly() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Findable"))

        #expect(archive.artifact(withID: artifact.uid)?.uid == artifact.uid)
        #expect(archive.artifact(withID: ArtifactID("ART-nope")) == nil)
    }

    @Test func artifactsListsEverySummary() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Alpha"))
        _ = try archive.addArtifact(.sample(title: "Beta"))

        let summaries = archive.artifacts()
        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.title)) == ["Alpha", "Beta"])
        for summary in summaries {
            #expect(!summary.slug.isEmpty)
        }
    }

    @Test func primaryDateIsChronologicallyEarliestEventVerbatim() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        // "19XX" (the 1900s, earliest bound 1900) is chronologically earlier than
        // "1920", but sorts *after* it as a plain string ('2' < 'X'), so the old
        // lexicographic-min picked "1920". The EDTF bound orders it correctly, and
        // the summary keeps the earliest event's value verbatim.
        let artifact = try archive.addArtifact(
            .sample(
                title: "Mixed-precision dates",
                events: [
                    Event(type: "Census", date: "1920"),
                    Event(type: "Estimated birth", date: "19XX"),
                ]))
        #expect(archive.artifacts().first { $0.uid == artifact.uid }?.primaryDate == "19XX")
    }

    @Test func primaryDateSkipsUnparseableDates() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        // A non-EDTF date can't be ordered, so it's skipped; the parseable one wins.
        let mixed = try archive.addArtifact(
            .sample(
                title: "Mixed",
                events: [
                    Event(type: "Note", date: "sometime in the spring"),
                    Event(type: "Census", date: "1920"),
                ]))
        #expect(archive.artifacts().first { $0.uid == mixed.uid }?.primaryDate == "1920")
        // All-unparseable → no orderable primary date.
        let unparseable = try archive.addArtifact(
            .sample(title: "Vague", events: [Event(type: "Note", date: "long ago")]))
        #expect(archive.artifacts().first { $0.uid == unparseable.uid }?.primaryDate == nil)
    }

    @Test func dateRangeMatchesApproximateAndRangedEvents() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(
            .sample(title: "About 1920", events: [Event(type: "Birth", date: "1920~")]))
        _ = try archive.addArtifact(
            .sample(title: "Range 1900-1905", events: [Event(type: "Span", date: "1900/1905")]))
        _ = try archive.addArtifact(
            .sample(title: "On or after 1960", events: [Event(type: "Move", date: "1960/..")]))

        // A 1902–1904 window overlaps the range and (via the open end) nothing else.
        let midRange = archive.artifacts(matching: ArtifactQuery(dateRange: 1902...1904))
        #expect(midRange.map(\.title) == ["Range 1900-1905"])
        // A 1918–1922 window catches the approximate 1920.
        let approx = archive.artifacts(matching: ArtifactQuery(dateRange: 1918...1922))
        #expect(approx.map(\.title) == ["About 1920"])
        // A modern window catches only the open-ended "1960 or later".
        let modern = archive.artifacts(matching: ArtifactQuery(dateRange: 1990...2000))
        #expect(modern.map(\.title) == ["On or after 1960"])
    }

    /// A multi-person record states its dates and places *per mention* (slice 44h), so
    /// a record whose evidence lives only there must still be findable. Both widenings
    /// are additive — nothing that matched before stops matching — but without them the
    /// facts scoped to a mention would be the one thing a record says that neither free
    /// text nor the year filter can reach.
    @Test func searchAndDateRangeCoverMentionScopedFacts() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(
            .sample(
                title: "Metrical register page 14",
                personsMentioned: [
                    PersonMention(
                        localRef: "p1", nameAsRecorded: "Majer Sternfeld", role: .subject,
                        informationQuality: .primary,
                        facts: [RecordedFact(type: .birth, date: "1892", place: "Łomża")]),
                    PersonMention(
                        localRef: "p2", nameAsRecorded: "Sura Sternfeld", role: .parent,
                        informationQuality: .secondary),
                ]))
        // A record with the same shape but no mention facts, to prove the filters
        // discriminate rather than matching everything.
        _ = try archive.addArtifact(
            .sample(
                title: "Unrelated page",
                personsMentioned: [
                    PersonMention(
                        localRef: "p1", nameAsRecorded: "Jan Kowalski", role: .subject,
                        informationQuality: .primary)
                ]))

        let byPlace = archive.artifacts(matching: ArtifactQuery(text: "Łomża"))
        #expect(byPlace.map(\.title) == ["Metrical register page 14"])
        let byFactType = archive.artifacts(matching: ArtifactQuery(text: "Birth"))
        #expect(byFactType.map(\.title) == ["Metrical register page 14"])
        let byYear = archive.artifacts(matching: ArtifactQuery(dateRange: 1890...1895))
        #expect(byYear.map(\.title) == ["Metrical register page 14"])
        // …and a window the mention fact does not fall in still excludes it.
        #expect(archive.artifacts(matching: ArtifactQuery(dateRange: 1930...1940)).isEmpty)
    }

    @Test func artifactsMatchingFiltersByTextTagsTierAndDateRange() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        _ = try archive.addArtifact(
            .sample(
                title: "1920 Census of Cook County",
                sourceAuthorityTier: .census,
                events: [Event(type: "Census", date: "1920-01-15")],
                tags: ["genealogy", "illinois"],
                notes: "Smith family enumeration"
            ))
        _ = try archive.addArtifact(
            .sample(
                title: "Birth certificate",
                sourceAuthorityTier: .vital,
                events: [Event(type: "Birth", date: "1895-03-02")],
                tags: ["vital-record"]
            ))

        let byText = archive.artifacts(matching: ArtifactQuery(text: "cook county"))
        #expect(byText.map(\.title) == ["1920 Census of Cook County"])

        let byTags = archive.artifacts(matching: ArtifactQuery(tags: ["illinois"]))
        #expect(byTags.map(\.title) == ["1920 Census of Cook County"])

        let byTier = archive.artifacts(matching: ArtifactQuery(sourceTier: .vital))
        #expect(byTier.map(\.title) == ["Birth certificate"])

        let byDateRange = archive.artifacts(matching: ArtifactQuery(dateRange: 1900...1930))
        #expect(byDateRange.map(\.title) == ["1920 Census of Cook County"])

        let byNotesText = archive.artifacts(matching: ArtifactQuery(text: "smith family"))
        #expect(byNotesText.map(\.title) == ["1920 Census of Cook County"])

        let byNothing = archive.artifacts(matching: ArtifactQuery())
        #expect(byNothing.count == 2)
    }

    /// **Promoting an open-vocabulary case must not strand the spelling an older build
    /// stored.** Slice 46 made `government` a known case; a pre-46 archive holds
    /// `"Government"` as `.unknown("Government")`, and a query for it now folds to
    /// `.government`, so an `==` comparison stopped finding the record. The control is
    /// the other half of the proof: `"ShipManifest"`, which is *not* a known case and will
    /// not become one, matched the whole time — so the casing was never the cause, the
    /// promotion was. (It stands here for a label this build never heard of, not for a
    /// cataloguing recommendation: a manifest is a `government` record — see spec §6.1.)
    @Test func tierQueryFindsAPrePromotionSpelling() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        _ = try archive.addArtifact(
            .sample(
                title: "Naturalization certificate", sourceAuthorityTier: .unknown("Government"))
        )
        _ = try archive.addArtifact(
            .sample(title: "Uncatalogued scan", sourceAuthorityTier: .unknown("ShipManifest")))

        let promoted = archive.artifacts(
            matching: ArtifactQuery(sourceTier: .parsingLeniently("Government")))
        #expect(promoted.map(\.title) == ["Naturalization certificate"])

        // The canonical spelling reaches the stored variant too — the same fold, from
        // the other side.
        let canonical = archive.artifacts(matching: ArtifactQuery(sourceTier: .government))
        #expect(canonical.map(\.title) == ["Naturalization certificate"])

        let control = archive.artifacts(
            matching: ArtifactQuery(sourceTier: .parsingLeniently("ShipManifest")))
        #expect(control.map(\.title) == ["Uncatalogued scan"])
    }

    /// **An uncatalogued artifact matches no tier query (46b).** The alternative — letting
    /// an absent tier match anything — would make `--source-tier vital` quietly widen as
    /// the archive grows *less* complete, which is the opposite of what a facet is for.
    @Test func tierQuerySkipsUncataloguedArtifacts() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        _ = try archive.addArtifact(
            .sample(title: "Birth certificate", sourceAuthorityTier: .vital))
        let uncatalogued = try archive.addArtifact(
            .sample(title: "Dragged-in scan", sourceAuthorityTier: nil))
        #expect(uncatalogued.sourceAuthorityTier == nil)

        let vital = archive.artifacts(matching: ArtifactQuery(sourceTier: .vital))
        #expect(vital.map(\.title) == ["Birth certificate"])

        // It is still in the archive — unfaceted lookups must not lose it.
        #expect(archive.artifacts(matching: ArtifactQuery()).count == 2)
    }

    @Test func artifactsMatchingFreeTextMatchesWholeTagsNotPartials() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        _ = try archive.addArtifact(
            .sample(title: "Untitled scan", tags: ["marriage", "illinois"]))
        _ = try archive.addArtifact(.sample(title: "Other document", tags: ["birth"]))

        // Free text matches a tag exactly (case-insensitively), even though the
        // term appears in neither title nor notes.
        let exact = archive.artifacts(matching: ArtifactQuery(text: "marriage"))
        #expect(exact.map(\.title) == ["Untitled scan"])
        let exactCased = archive.artifacts(matching: ArtifactQuery(text: "MARRIAGE"))
        #expect(exactCased.map(\.title) == ["Untitled scan"])

        // A partial tag does NOT match — tags are atomic labels — and "marri" is
        // not a substring of any title/notes either.
        let partial = archive.artifacts(matching: ArtifactQuery(text: "marri"))
        #expect(partial.isEmpty)

        // Substring matching over title/transcript/notes is unaffected.
        let substring = archive.artifacts(matching: ArtifactQuery(text: "scan"))
        #expect(substring.map(\.title) == ["Untitled scan"])
    }

    @Test func artifactsMatchingSearchesTranscriptFileTextAndSurvivesRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let artifact = try archive.addArtifact(.sample(title: "Diary page"))
        _ = try archive.addArtifact(.sample(title: "Unrelated"))

        // A transcript stored as a *file* (role: .transcript), not the inline
        // `Artifact.transcript` field — its words live on disk, outside record.json.
        let transcript = try TestSupport.makeSourceFile(
            named: "page1.txt", contents: "Eleanor wrote of the harvest in autumn.")
        _ = try archive.attachFile(copyingFrom: transcript, to: artifact.uid, role: .transcript)

        // A non-transcript file's text must NOT be searchable.
        let accessCopy = try TestSupport.makeSourceFile(
            named: "caption.txt", contents: "zucchini")
        _ = try archive.attachFile(copyingFrom: accessCopy, to: artifact.uid, role: .accessCopy)

        // Free text finds a word that appears only in the transcript file.
        let byFileText = archive.artifacts(matching: ArtifactQuery(text: "harvest"))
        #expect(byFileText.map(\.title) == ["Diary page"])
        let casedFileText = archive.artifacts(matching: ArtifactQuery(text: "ELEANOR"))
        #expect(casedFileText.map(\.title) == ["Diary page"])

        // A word only in a non-transcript-role file is not indexed.
        #expect(archive.artifacts(matching: ArtifactQuery(text: "zucchini")).isEmpty)

        // Rebuilding the index from the on-disk archive re-reads the transcript
        // file, so its content stays searchable (the index is a rebuildable cache).
        try archive.rebuildIndex()
        let afterRebuild = archive.artifacts(matching: ArtifactQuery(text: "harvest"))
        #expect(afterRebuild.map(\.title) == ["Diary page"])
        #expect(archive.artifacts(matching: ArtifactQuery(text: "zucchini")).isEmpty)
    }

    @Test func artifactsMatchingMentioningFiltersOnNameAsRecorded() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "John Smith", role: .subject,
            informationQuality: .primary)
        _ = try archive.addArtifact(.sample(title: "Has John", personsMentioned: [mention]))
        _ = try archive.addArtifact(.sample(title: "No mentions"))

        let results = archive.artifacts(matching: ArtifactQuery(mentioning: "john"))
        #expect(results.map(\.title) == ["Has John"])
    }

    @Test func artifactsMatchingFreeTextSearchesPersonsPlacesAndEvents() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        // A record whose searchable words live ONLY in structured metadata — no
        // matching title/transcript/notes — exercises the search-coverage gap directly.
        _ = try archive.addArtifact(
            .sample(
                title: "Untitled scan",
                personsMentioned: [
                    PersonMention(
                        localRef: "p1", nameAsRecorded: "Szlama Feldberg", role: .subject,
                        informationQuality: .primary)
                ],
                events: [Event(type: "Marriage", date: "1872-03-02", location: "Rypin")],
                locations: [Location(asRecorded: "Kutnie", normalized: "Kutno, Poland")]
            ))
        _ = try archive.addArtifact(.sample(title: "Unrelated record"))

        // Person name recorded only in personsMentioned.
        #expect(
            archive.artifacts(matching: ArtifactQuery(text: "feldberg")).map(\.title)
                == ["Untitled scan"])
        // Place recorded only in locations (as-recorded and normalized both searchable).
        // Neither spelling contains the other, so each query can only hit its own field.
        #expect(
            archive.artifacts(matching: ArtifactQuery(text: "kutnie")).map(\.title)
                == ["Untitled scan"])
        #expect(
            archive.artifacts(matching: ArtifactQuery(text: "kutno")).map(\.title)
                == ["Untitled scan"])
        // Event type and event location.
        #expect(
            archive.artifacts(matching: ArtifactQuery(text: "marriage")).map(\.title)
                == ["Untitled scan"])
        #expect(
            archive.artifacts(matching: ArtifactQuery(text: "rypin")).map(\.title)
                == ["Untitled scan"])
        // A word in none of the fields still misses.
        #expect(archive.artifacts(matching: ArtifactQuery(text: "nonesuch")).isEmpty)
    }

    @Test func artifactsMentioningFindsViaEvidenceLinks() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "John Smith", role: .subject,
            informationQuality: .primary)
        let linkedArtifact = try archive.addArtifact(
            .sample(title: "Linked artifact", personsMentioned: [mention]))
        _ = try archive.addArtifact(.sample(title: "Unlinked artifact"))
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))
        _ = try archive.link(
            MentionRef(artifact: linkedArtifact.uid, localRef: "p1"), to: person.uid)

        let mentioning = archive.artifacts(mentioning: person.uid)
        #expect(mentioning.map(\.title) == ["Linked artifact"])

        let strangerID = PersonID("PER-stranger")
        #expect(archive.artifacts(mentioning: strangerID).isEmpty)
    }

    @Test func artifactWithExternalIdentifierMatchesSchemeAndValue() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let externalID = ExternalIdentifier(
            scheme: .ark, value: "ark:/12345/x6", repository: "FamilySearch")
        _ = try archive.addArtifact(
            .sample(title: "Federated record", externalIdentifiers: [externalID]))
        _ = try archive.addArtifact(.sample(title: "Local-only record"))

        let found = archive.artifact(withExternalIdentifier: externalID)
        #expect(found?.title == "Federated record")

        let miss = archive.artifact(
            withExternalIdentifier: ExternalIdentifier(scheme: .doi, value: "10.0/nope"))
        #expect(miss == nil)
    }

    @Test func artifactAtPathResolvesFolderRecordAndAttachedFile() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Path lookups"))
        let slug = try #require(archive.artifacts().first?.slug)

        let source = try TestSupport.makeSourceFile(named: "scan.tif")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .accessCopy)

        #expect(archive.artifact(atPath: "artifacts/\(slug)")?.uid == artifact.uid)
        #expect(archive.artifact(atPath: "artifacts/\(slug)/record.json")?.uid == artifact.uid)
        #expect(
            archive.artifact(atPath: "artifacts/\(slug)/\(attached.entry.path)")?.uid
                == artifact.uid)
        #expect(archive.artifact(atPath: "artifacts/does-not-exist") == nil)
    }

    @Test func artifactsContainingFileWithSHA256FindsAcrossArtifacts() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let artifactA = try archive.addArtifact(.sample(title: "A"))
        let artifactB = try archive.addArtifact(.sample(title: "B"))

        let sourceA = try TestSupport.makeSourceFile(named: "shared.txt", contents: "shared bytes")
        let sourceB = try TestSupport.makeSourceFile(
            named: "shared-copy.txt", contents: "shared bytes")
        let attachedA = try archive.attachFile(
            copyingFrom: sourceA, to: artifactA.uid, role: .accessCopy)
        _ = try archive.attachFile(copyingFrom: sourceB, to: artifactB.uid, role: .accessCopy)

        let results = archive.artifacts(containingFileWithSHA256: attachedA.entry.sha256)
        #expect(Set(results.map(\.title)) == ["A", "B"])

        #expect(archive.artifacts(containingFileWithSHA256: "0000").isEmpty)
    }

    // MARK: - Person lookups

    @Test func personWithIDFindsAndMisses() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))

        #expect(archive.person(withID: person.uid)?.uid == person.uid)
        #expect(archive.person(withID: PersonID("PER-nope")) == nil)
    }

    @Test func personsListsSummariesWithDisplayNames() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        _ = try archive.addPerson(.sample(given: "Alan", surname: "Turing"))

        let summaries = archive.persons()
        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.displayName)) == ["Ada Lovelace", "Alan Turing"])
    }

    @Test func personsMatchingFiltersByTextFactTypeAndDateRange() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        _ = try archive.addPerson(
            PersonDraft(
                given: "Ada", surname: "Lovelace",
                facts: [PersonFact(type: .birth, date: "1815-12-10", place: "London, England")]
            ))
        _ = try archive.addPerson(
            PersonDraft(
                given: "Alan", surname: "Turing",
                facts: [PersonFact(type: .birth, date: "1912-06-23", place: "Maida Vale, England")]
            ))

        let byText = archive.persons(matching: PersonQuery(text: "lovelace"))
        #expect(byText.map(\.displayName) == ["Ada Lovelace"])

        let byPlace = archive.persons(matching: PersonQuery(text: "maida vale"))
        #expect(byPlace.map(\.displayName) == ["Alan Turing"])

        let byFactType = archive.persons(matching: PersonQuery(factTypes: [.birth]))
        #expect(byFactType.count == 2)

        let byDateRange = archive.persons(matching: PersonQuery(dateRange: 1900...1920))
        #expect(byDateRange.map(\.displayName) == ["Alan Turing"])
    }
}
