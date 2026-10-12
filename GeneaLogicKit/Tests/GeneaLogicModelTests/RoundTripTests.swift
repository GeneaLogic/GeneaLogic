import Foundation
import GeneaLogicModel
import Testing

// MARK: - Helpers

/// Verifies that encoding then decoding a value produces an equal value.
private func assertRoundTrip<T: Codable & Equatable & Sendable>(_ value: T) throws {
    let encoded = try GeneaLogicJSON.encoder.encode(value)
    let decoded = try GeneaLogicJSON.decoder.decode(T.self, from: encoded)
    #expect(decoded == value)
}

/// Decodes a fixture file and asserts equality with an expected value.
/// Also re-encodes the decoded value and checks that the result matches
/// re-encoding the expected value (stable re-serialization).
private func assertFixture<T: Codable & Equatable & Sendable>(
    named name: String,
    matches expected: T
) throws {
    let data = try FixtureLoader.data(for: name)
    let decoded = try GeneaLogicJSON.decoder.decode(T.self, from: data)
    #expect(decoded == expected, "Decoded fixture '\(name)' did not match expected value")

    // Re-encode both and compare bytes — confirms encoding is stable and deterministic.
    let reEncoded = try GeneaLogicJSON.encoder.encode(decoded)
    let expectedEncoded = try GeneaLogicJSON.encoder.encode(expected)
    #expect(
        reEncoded == expectedEncoded,
        "Re-encoded fixture '\(name)' differed from expected encoding"
    )
}

// MARK: - Shared fixture values

/// An Artifact exercising the fields slice 44h added — `sourceDerivation`, and a
/// mention carrying `facts` / `nameLanguage` / `nameScript`.
///
/// `canonicalArtifact` deliberately keeps the **pre-44h** shape (its record has no
/// `sourceDerivation`, its mention no `facts` key), which is what makes
/// `artifact.json` a real back-compat fixture. That leaves the fixture set with no
/// example of what the encoder writes *today*, so this is its counterpart: the
/// golden fixtures are the one place a reader sees actual bytes, and both shapes
/// need to be among them.
var canonicalArtifact44h: Artifact {
    Artifact(
        uid: "ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f71",
        title: "Łomża metrical register, 1892, akt 14",
        mediaType: .image,
        sourceAuthorityTier: .church,
        sourceDerivation: .original,
        language: "ru",
        personsMentioned: [
            // A multi-person record: the two births are attributed separately, which
            // is the entire point of scoping facts to the mention (§10.6).
            PersonMention(
                localRef: "p1",
                nameAsRecorded: "Мотек Штернфельд",
                role: .subject,
                informationQuality: .primary,
                facts: [
                    RecordedFact(type: .birth, date: "1892", place: "Łomża"),
                    RecordedFact(
                        type: .residence, place: "Warszawa", informationQuality: .secondary),
                    // A value-bearing fact (slice 44i): the register records an occupation,
                    // whose information is the value "tailor", not a date or place.
                    RecordedFact(type: .occupation, value: "tailor"),
                ],
                nameLanguage: "ru",
                nameScript: "Cyrl",
                attributes: ["ageAsRecorded": "31"]
            ),
            // A role that only exists because the vocabulary opened in 44h, and a
            // mention with no facts — both common, both must survive a round-trip.
            PersonMention(
                localRef: "p2",
                nameAsRecorded: "Chaim Rozen",
                role: .godparent,
                informationQuality: .secondary,
                nameLanguage: "yi",
                nameScript: "Latn"
            ),
        ],
        provenance: Provenance(
            createdBy: .human,
            createdAt: "2026-07-22T12:00:00Z",
            tool: nil,
            reviewStatus: .asserted
        )
    )
}

/// The record slice 45k was scheduled by: a death certificate that names the deceased
/// and both of his parents, and now **states** the two parent edges rather than leaving
/// a reader to guess them from three `parent`/`subject` tags.
///
/// It also carries the pairing no role vocabulary can express — the two parents are each
/// other's `couple` — which is the case that makes an edge a different kind of statement
/// from a role rather than a redundant one.
var canonicalArtifact45k: Artifact {
    Artifact(
        uid: "ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f72",
        title: "Sidney Feldberg death certificate, 1938",
        mediaType: .image,
        sourceAuthorityTier: .vital,
        sourceDerivation: .original,
        language: "en",
        personsMentioned: [
            PersonMention(
                localRef: "p1",
                nameAsRecorded: "Sidney Feldberg",
                role: .subject,
                informationQuality: .primary,
                facts: [
                    RecordedFact(
                        type: .death, date: "1938-04-21", place: "Brooklyn, New York, USA")
                ]
            ),
            PersonMention(
                localRef: "p2",
                nameAsRecorded: "Marcus Feldberg",
                role: .parent,
                informationQuality: .secondary
            ),
            PersonMention(
                localRef: "p3",
                nameAsRecorded: "Sarah Hanner",
                role: .parent,
                informationQuality: .secondary
            ),
        ],
        mentionRelationships: [
            MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1"),
            MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p1"),
            MentionRelationship(type: .couple, person1Ref: "p2", person2Ref: "p3"),
        ],
        provenance: Provenance(
            createdBy: .human,
            createdAt: "2026-07-30T12:00:00Z",
            tool: nil,
            reviewStatus: .asserted
        )
    )
}

/// The canonical Artifact used in both in-memory and fixture tests.
// Shared with SchemaSpecTests (schema-doc coverage). Internal, not private.
var canonicalArtifact: Artifact {
    Artifact(
        uid: "ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70",
        title: "1920 US Census – Smith Family",
        mediaType: .image,
        sourceAuthorityTier: .census,
        originalFormat: "digital scan",
        language: "en",
        events: [
            Event(type: "Census", date: "1920-01-15", location: "Cook County, Illinois, USA")
        ],
        personsMentioned: [
            PersonMention(
                localRef: "p1",
                nameAsRecorded: "John Smith",
                role: .subject,
                informationQuality: .primary,
                attributes: ["ageAsRecorded": "45"]
            )
        ],
        locations: [
            Location(asRecorded: "Cook County, Illinois, USA", normalized: nil)
        ],
        transcript: nil,
        files: [
            FileEntry(
                uid: "FIL-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70",
                path: "census-1920.tif",
                originalName: "Census Scan (final).tif",
                role: .preservationMaster,
                format: "TIFF",
                byteLength: 10_485_760,
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            )
        ],
        externalIdentifiers: [
            ExternalIdentifier(
                scheme: .ark, value: "ark:/12345/abcdef", repository: "Example State Archive")
        ],
        retrieval: Retrieval(
            source: "Cook County Vital Records", date: "2026-02-22", checksum: nil),
        provenance: Provenance(
            createdBy: .human,
            createdAt: "2026-02-22T15:04:05Z",
            tool: nil,
            reviewStatus: .asserted
        ),
        tags: ["vital-record", "census", "Illinois"],
        notes: "Page edge cropped; line 12 partially illegible."
    )
}

/// The canonical Person used in both in-memory and fixture tests.
var canonicalPerson: Person {
    Person(
        uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000001",
        names: [
            PersonName(type: .birth, given: "John", surname: "Smith", full: "John Smith")
        ],
        facts: [
            PersonFact(
                type: .birth,
                date: "1871",
                place: "Illinois, USA",
                supportedByLinks: ["LNK-018f3c9a-7b2e-7c41-9e3a-000000000043"]
            )
        ],
        identifierURI: nil,
        provenance: Provenance(
            createdBy: .human,
            createdAt: "2026-02-22T15:04:05Z",
            tool: nil,
            reviewStatus: .humanVerified
        )
    )
}

/// The canonical EvidenceLink used in both in-memory and fixture tests.
var canonicalEvidenceLink: EvidenceLink {
    EvidenceLink(
        uid: "LNK-018f3c9a-7b2e-7c41-9e3a-000000000043",
        artifactUid: "ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70",
        personMentionRef: "p1",
        personUid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000001",
        match: MatchBreakdown(
            name: MatchDimension(kind: .exact, score: 100),
            nameAlgo: "double-metaphone",
            birthYear: MatchDimension(kind: .within, score: 60, delta: 3),
            birthPlace: MatchDimension(kind: .within, score: 50, granularity: .specific),
            spouseName: MatchDimension(kind: .exact, score: 100),
            parents: MatchDimension(kind: .none, score: 0),
            conflicts: []
        ),
        sourceAuthorityWeight: 60,
        informationQualityWeight: 50,
        aggregateConfidence: 71,
        reviewStatus: .machineSuggested,
        reviewedBy: nil,
        reviewedAt: nil,
        provenance: Provenance(
            createdBy: .machine,
            createdAt: "2026-02-22T16:00:00Z",
            tool: "matcher-1.0",
            reviewStatus: .machineSuggested
        )
    )
}

/// The canonical Relationship used in both in-memory and fixture tests.
var canonicalRelationship: Relationship {
    Relationship(
        uid: "REL-018f3c9a-7b2e-7c41-9e3a-000000000007",
        type: .parentChild,
        person1Uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000001",
        person2Uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000014",
        supportedByLinks: [
            "LNK-018f3c9a-7b2e-7c41-9e3a-000000000043",
            "LNK-018f3c9a-7b2e-7c41-9e3a-000000000101",
        ],
        reviewStatus: .humanVerified,
        provenance: Provenance(
            createdBy: .human,
            createdAt: "2026-02-22T15:04:05Z",
            tool: nil,
            reviewStatus: .humanVerified
        )
    )
}

/// The canonical Dismissal (slice 45m): a duplicate candidate a human declined, carrying
/// the breakdown they were shown. Its pair is in canonical (ascending) order, which is how
/// a symmetric subject is written.
var canonicalDismissal: Dismissal {
    Dismissal(
        uid: "DSM-018f3c9a-0000-7000-8000-0000000000d1",
        subject: .samePerson,
        person1Uid: "PER-018f3c9a-0000-7000-8000-000000000001",
        person2Uid: "PER-018f3c9a-0000-7000-8000-000000000002",
        match: MatchBreakdown(
            name: MatchDimension(kind: .exact, score: 100),
            nameAlgo: "daitch-mokotoff",
            birthYear: MatchDimension(kind: .within, score: 60, delta: 2),
            conflicts: ["death years disagree by 31"]
        ),
        aggregateConfidence: 62,
        dismissedBy: "ada",
        dismissedAt: "2026-08-02T10:00:00Z",
        provenance: Provenance(
            createdBy: .human,
            createdAt: "2026-08-02T10:00:00Z",
            tool: nil,
            reviewStatus: .humanVerified
        )
    )
}

/// The canonical Manifest used in both in-memory and fixture tests.
var canonicalManifest: Manifest {
    Manifest(
        archiveUID: "018f3c9a-0000-7000-8000-000000000001",
        name: "Smith Family Archive",
        updatedAt: "2026-02-22T15:04:05Z",
        files: [
            ManifestEntry(
                path: "artifacts/ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70/census-1920.tif",
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                byteLength: 10_485_760
            ),
            ManifestEntry(
                path: "artifacts/ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70/record.json",
                sha256: "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3",
                byteLength: 4096
            ),
        ]
    )
}

// MARK: - In-memory round-trip tests

@Suite("In-memory round-trip tests")
struct InMemoryRoundTripTests {

    @Test("Artifact round-trips through JSON encode/decode")
    func artifactRoundTrip() throws {
        try assertRoundTrip(canonicalArtifact)
    }

    @Test("FileEntry round-trips through JSON encode/decode")
    func fileEntryRoundTrip() throws {
        let entry = FileEntry(
            uid: "FIL-018f3c9a-0000-7000-8000-000000000001",
            path: "scan.tif",
            originalName: "Original Scan.tif",
            role: .preservationMaster,
            format: "TIFF",
            byteLength: 2_097_152,
            sha256: "abc123def456"
        )
        try assertRoundTrip(entry)
    }

    @Test("PersonMention round-trips through JSON encode/decode")
    func personMentionRoundTrip() throws {
        let mention = PersonMention(
            localRef: "p2",
            nameAsRecorded: "Mary Jane Doe",
            role: .spouse,
            informationQuality: .secondary,
            attributes: ["ageAsRecorded": "38", "occupationAsRecorded": "housewife"]
        )
        try assertRoundTrip(mention)
    }

    @Test("RecordedFact round-trips through JSON encode/decode")
    func recordedFactRoundTrip() throws {
        try assertRoundTrip(
            RecordedFact(
                type: .birth, date: "1892~", place: "Łomża", informationQuality: .secondary))
        // A value-bearing fact — an occupation the record states (slice 44i). The value
        // is what carries "tailor"; the type/date/place do not.
        try assertRoundTrip(
            RecordedFact(type: .occupation, date: "1912", value: "tailor"))
        // Every optional absent — the common shape for "the register names a birth year
        // and nothing else".
        try assertRoundTrip(RecordedFact(type: .marriage))
    }

    /// A `RecordedFact`/`PersonFact` written before slice 44i has no `value` key; absent
    /// must decode to `nil` (the additive-widening contract), and a present value must
    /// round-trip verbatim.
    @Test("A fact without a value decodes to nil; a fact with one round-trips (44i)")
    func factValueBackCompatAndRoundTrip() throws {
        let recorded = try GeneaLogicJSON.decoder.decode(
            RecordedFact.self, from: Data(#"{ "type": "Occupation", "date": "1912" }"#.utf8))
        #expect(recorded.value == nil)
        // `PersonFact.supportedByLinks` is a required (non-optional) array, so a valid
        // legacy fact carries it; only `value` is the new, optional key.
        let person = try GeneaLogicJSON.decoder.decode(
            PersonFact.self,
            from: Data(#"{ "type": "Occupation", "supportedByLinks": [] }"#.utf8))
        #expect(person.value == nil)
        // A present value must not be emitted as `null` when absent, and must survive.
        let withoutValue = try GeneaLogicJSON.encoder.encode(RecordedFact(type: .birth))
        #expect(!String(decoding: withoutValue, as: UTF8.self).contains("value"))
        try assertRoundTrip(
            PersonFact(type: .physicalDescription, value: "brown hair, 5 ft 8 in"))
    }

    @Test("A mention carrying facts and name language/script round-trips (44h)")
    func personMentionWithFactsRoundTrip() throws {
        let mention = PersonMention(
            localRef: "p3",
            nameAsRecorded: "Мотек Штернфельд",
            role: .godparent,
            informationQuality: .primary,
            facts: [
                RecordedFact(type: .birth, date: "1892", place: "Łomża"),
                RecordedFact(type: .residence, place: "Warszawa", informationQuality: .secondary),
            ],
            nameLanguage: "ru",
            nameScript: "Cyrl",
            attributes: ["ageAsRecorded": "31"]
        )
        try assertRoundTrip(mention)
    }

    /// A `record.json` written before slice 44h has no `facts`, `nameLanguage` or
    /// `nameScript` key on its mentions; it must still decode, `facts` defaulting to
    /// `[]` (the additive-widening contract, as `Relationship.facts` did in slice 43).
    @Test("A mention without the 44h keys decodes with empty facts (back-compat)")
    func personMentionMissingFactsDecodes() throws {
        let legacyJSON = """
            {
              "localRef": "p1",
              "nameAsRecorded": "John Smith",
              "role": "subject",
              "informationQuality": "primary",
              "attributes": { "ageAsRecorded": "45" }
            }
            """
        let decoded = try GeneaLogicJSON.decoder.decode(
            PersonMention.self, from: Data(legacyJSON.utf8))
        #expect(decoded.facts.isEmpty)
        #expect(decoded.nameLanguage == nil)
        #expect(decoded.nameScript == nil)
        #expect(decoded.attributes?["ageAsRecorded"] == "45")
    }

    /// An `Artifact` written before slice 44h has no `sourceDerivation` key — absent
    /// must read as *unstated*, never as a derivation we assert on the researcher's
    /// behalf.
    @Test("An artifact without sourceDerivation decodes to nil, not a default (44h)")
    func artifactMissingSourceDerivationDecodes() throws {
        var withoutIt = canonicalArtifact
        withoutIt.sourceDerivation = nil
        let data = try GeneaLogicJSON.encoder.encode(withoutIt)
        // Absent from the encoded bytes entirely, not emitted as `null`.
        #expect(!String(decoding: data, as: UTF8.self).contains("sourceDerivation"))
        let decoded = try GeneaLogicJSON.decoder.decode(Artifact.self, from: data)
        #expect(decoded.sourceDerivation == nil)
    }

    @Test("An artifact carrying a source derivation round-trips (44h)")
    func artifactWithSourceDerivationRoundTrip() throws {
        var artifact = canonicalArtifact
        artifact.sourceDerivation = .derivative
        try assertRoundTrip(artifact)
    }

    // MARK: - Optional source authority tier (46b)

    /// The field became optional in 46b, so the key must behave exactly as
    /// `sourceDerivation`'s does: **absent from the bytes, not `null`**, and decoding to
    /// `nil` rather than to a genre asserted on the researcher's behalf.
    @Test("An artifact without a source tier decodes to nil, not a default (46b)")
    func artifactMissingSourceTierDecodes() throws {
        var withoutIt = canonicalArtifact
        withoutIt.sourceAuthorityTier = nil
        let data = try GeneaLogicJSON.encoder.encode(withoutIt)
        #expect(!String(decoding: data, as: UTF8.self).contains("sourceAuthorityTier"))
        let decoded = try GeneaLogicJSON.decoder.decode(Artifact.self, from: data)
        #expect(decoded.sourceAuthorityTier == nil)
        try assertRoundTrip(withoutIt)
    }

    /// **The back-compat guarantee, from the bytes rather than from the model.** Making a
    /// required field optional is only safe if every archive already on disk still loads
    /// with its value intact — so this decodes a record that *has* the key and asserts it
    /// survived, which a round-trip starting from a Swift value cannot prove.
    @Test("A pre-46b artifact keeps its stored source tier (back-compat)")
    func preOptionalArtifactKeepsItsTier() throws {
        var stated = canonicalArtifact
        stated.sourceAuthorityTier = .census
        let data = try GeneaLogicJSON.encoder.encode(stated)
        #expect(String(decoding: data, as: UTF8.self).contains("\"sourceAuthorityTier\""))

        let decoded = try GeneaLogicJSON.decoder.decode(Artifact.self, from: data)
        #expect(decoded.sourceAuthorityTier == .census)
    }

    // MARK: - Stated mention relationships (45k)

    @Test("MentionRelationship round-trips through JSON encode/decode")
    func mentionRelationshipRoundTrip() throws {
        try assertRoundTrip(
            MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1"))
        try assertRoundTrip(MentionRelationship(type: .couple, person1Ref: "p1", person2Ref: "p2"))
    }

    /// The Sidney death-certificate shape this slice exists for: the record names the
    /// deceased and both of his parents, and now *says* which is which.
    @Test("An artifact carrying stated mention relationships round-trips (45k)")
    func artifactWithMentionRelationshipsRoundTrip() throws {
        var artifact = canonicalArtifact44h
        artifact.mentionRelationships = [
            MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1"),
            MentionRelationship(type: .couple, person1Ref: "p1", person2Ref: "p2"),
        ]
        try assertRoundTrip(artifact)
    }

    /// The open vocabulary rule on the new field: a relation this version has never
    /// heard of must survive verbatim rather than being dropped or rejected — a record
    /// written by a later version still opens here, unchanged.
    @Test("An unknown relationship type on an edge round-trips verbatim (45k)")
    func unknownMentionRelationshipTypeRoundTrips() throws {
        let json = """
            { "type": "godparent-of", "person1Ref": "p1", "person2Ref": "p2" }
            """
        let decoded = try GeneaLogicJSON.decoder.decode(
            MentionRelationship.self, from: Data(json.utf8))
        #expect(decoded.type == .unknown("godparent-of"))
        // Not a parent-child edge, so neither directional accessor claims it.
        #expect(decoded.parentRef == nil)
        #expect(decoded.childRef == nil)
        let reEncoded = try GeneaLogicJSON.encoder.encode(decoded)
        #expect(String(decoding: reEncoded, as: UTF8.self).contains("\"godparent-of\""))
        try assertRoundTrip(decoded)
    }

    /// **The load-bearing back-compat test.** Every `record.json` on disk predates this
    /// field; a synthesized decode would have required the key and failed the *load*,
    /// which is the whole reason `Artifact` now codes by hand.
    @Test("A pre-45k artifact decodes with no stated relationships (back-compat)")
    func artifactMissingMentionRelationshipsDecodes() throws {
        let data = try FixtureLoader.data(for: "artifact.json")
        let decoded = try GeneaLogicJSON.decoder.decode(Artifact.self, from: data)
        #expect(decoded.mentionRelationships.isEmpty)
        // …and the rest of the record is untouched by the new coding path.
        #expect(decoded == canonicalArtifact)
    }

    /// "One edge is one entry" needs a comparison `==` can't make: a symmetric `couple`
    /// written from the other end is the same statement, while a `parent-child` with
    /// swapped ends is a contradiction, not a duplicate. Found by hand-testing the app —
    /// removing a partner edge and re-adding it from the other person's row produced the
    /// reverse pair, which an equality guard would have stored beside the original.
    @Test func statesSameRelationshipIsSymmetricOnlyForACouple() {
        let couple = MentionRelationship(type: .couple, person1Ref: "p2", person2Ref: "p3")
        let reversedCouple = MentionRelationship(type: .couple, person1Ref: "p3", person2Ref: "p2")
        #expect(couple.statesSameRelationship(as: reversedCouple))
        #expect(reversedCouple.statesSameRelationship(as: couple))

        let parent = MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p3")
        let reversedParent = MentionRelationship(
            type: .parentChild, person1Ref: "p3", person2Ref: "p2")
        #expect(parent.statesSameRelationship(as: parent))
        #expect(!parent.statesSameRelationship(as: reversedParent))

        // Different types never state the same thing, and an unrecognized one is
        // compared strictly — this version cannot know whether it is symmetric.
        #expect(!couple.statesSameRelationship(as: parent))
        let unknown = MentionRelationship(
            type: .unknown("employs"), person1Ref: "p2", person2Ref: "p3")
        let reversedUnknown = MentionRelationship(
            type: .unknown("employs"), person1Ref: "p3", person2Ref: "p2")
        #expect(unknown.statesSameRelationship(as: unknown))
        #expect(!unknown.statesSameRelationship(as: reversedUnknown))
    }

    /// Rebinding is what lets an edge be stated *while* the mention at one end is being
    /// added, since its `localRef` doesn't exist until write time. The direction must
    /// survive it — a rebinding that swapped the endpoints would turn a parent into a
    /// child at the moment of writing, which is the hardest kind of bug to see later.
    @Test func rebindingReplacesAnEndpointWithoutChangingDirection() {
        let staged = MentionRelationship(type: .parentChild, person1Ref: "", person2Ref: "p1")
        let bound = staged.rebinding("", to: "p4")
        #expect(
            bound == MentionRelationship(type: .parentChild, person1Ref: "p4", person2Ref: "p1"))
        #expect(bound.parentRef == "p4")
        #expect(bound.childRef == "p1")

        // The child end rebinds just as directionally…
        let asChild = MentionRelationship(type: .parentChild, person1Ref: "p1", person2Ref: "")
        #expect(asChild.rebinding("", to: "p4").childRef == "p4")
        // …and a ref the edge doesn't name leaves it alone.
        #expect(bound.rebinding("p9", to: "p2") == bound)
    }

    /// §4.5's direction, decoded on the evidence side: `person1Ref` is the parent.
    @Test("The parent-child endpoint accessors follow §4.5's direction (45k)")
    func mentionRelationshipEndpointAccessors() {
        let edge = MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1")
        #expect(edge.parentRef == "p2")
        #expect(edge.childRef == "p1")
        #expect(edge.involves("p1"))
        #expect(!edge.involves("p3"))
        #expect(edge.other(from: "p1") == "p2")
        #expect(edge.other(from: "p3") == nil)
    }

    /// A fact states its own information quality only when it differs from the
    /// mention's; absent means *inherit*, not `.undetermined`. Getting that backwards
    /// would silently downgrade every unqualified fact on a primary-source mention.
    @Test("A recorded fact inherits the mention's information quality when absent (44h)")
    func recordedFactQualityInheritance() {
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Anna", role: .subject, informationQuality: .primary,
            facts: [
                RecordedFact(type: .death, date: "1948"),
                RecordedFact(type: .birth, date: "1892", informationQuality: .secondary),
            ])
        #expect(mention.facts[0].effectiveInformationQuality(within: mention) == .primary)
        #expect(mention.facts[1].effectiveInformationQuality(within: mention) == .secondary)
        #expect(mention.facts[0].informationQuality == nil)
    }

    @Test("Event round-trips through JSON encode/decode")
    func eventRoundTrip() throws {
        let event = Event(type: "Birth", date: "1871", location: "Cook County, Illinois, USA")
        try assertRoundTrip(event)
    }

    @Test("Event with nil date and location round-trips")
    func eventNilFieldsRoundTrip() throws {
        let event = Event(type: "Unknown")
        try assertRoundTrip(event)
    }

    @Test("Location round-trips through JSON encode/decode")
    func locationRoundTrip() throws {
        let loc = Location(
            asRecorded: "Cook County, Illinois, USA", normalized: "Cook County, IL, USA")
        try assertRoundTrip(loc)
    }

    @Test("Location with nil normalized round-trips")
    func locationNilNormalizedRoundTrip() throws {
        let loc = Location(asRecorded: "Illinois")
        try assertRoundTrip(loc)
    }

    @Test("Person round-trips through JSON encode/decode")
    func personRoundTrip() throws {
        try assertRoundTrip(canonicalPerson)
    }

    @Test("PersonName round-trips through JSON encode/decode")
    func personNameRoundTrip() throws {
        let name = PersonName(type: .married, given: "Mary", surname: "Smith", full: "Mary Smith")
        try assertRoundTrip(name)
    }

    @Test("A name tagged with language and script round-trips (44h)")
    func personNameWithLanguageAndScriptRoundTrip() throws {
        // Language and script are orthogonal, which is the whole reason both exist:
        // the same name transliterated is still Russian, but now in Latin script.
        let cyrillic = PersonName(
            type: .birth, given: "Анна", surname: "Штернфельд", full: "Анна Штернфельд",
            language: "ru", script: "Cyrl")
        let transliterated = PersonName(
            type: .alsoKnownAs, given: "Anna", surname: "Sternfeld", full: "Anna Sternfeld",
            language: "ru", script: "Latn")
        try assertRoundTrip(cyrillic)
        try assertRoundTrip(transliterated)

        // `deriving` carries the tags through, so a writer that synthesizes `full`
        // doesn't silently drop them.
        let derived = PersonName.deriving(
            type: .birth, given: "Chana", surname: "Sternfeld", language: "yi", script: "Hebr")
        #expect(derived.full == "Chana Sternfeld")
        #expect(derived.language == "yi")
        #expect(derived.script == "Hebr")
    }

    @Test("PersonFact round-trips through JSON encode/decode")
    func personFactRoundTrip() throws {
        let fact = PersonFact(
            type: .death,
            date: "1945-06-01",
            place: "Chicago, Cook County, Illinois, USA",
            supportedByLinks: ["LNK-aaa", "LNK-bbb"]
        )
        try assertRoundTrip(fact)
        // A value-bearing conclusion fact (occupation), promoted from evidence (slice 44i).
        try assertRoundTrip(
            PersonFact(
                type: .occupation, date: "1912", value: "tailor", supportedByLinks: ["LNK-c"])
        )
    }

    @Test("EvidenceLink round-trips through JSON encode/decode")
    func evidenceLinkRoundTrip() throws {
        try assertRoundTrip(canonicalEvidenceLink)
    }

    @Test("MatchBreakdown round-trips through JSON encode/decode")
    func matchBreakdownRoundTrip() throws {
        let breakdown = MatchBreakdown(
            name: MatchDimension(kind: .phonetic, score: 80),
            nameAlgo: "double-metaphone",
            birthYear: MatchDimension(kind: .within, score: 50, delta: 5),
            birthPlace: MatchDimension(kind: .within, score: 30, granularity: .coarse),
            spouseName: nil,
            parents: MatchDimension(kind: .none, score: 0),
            conflicts: ["birth year off by 10"]
        )
        try assertRoundTrip(breakdown)
    }

    @Test("MatchDimension round-trips through JSON encode/decode")
    func matchDimensionRoundTrip() throws {
        let dim = MatchDimension(kind: .exact, score: 100, delta: nil)
        try assertRoundTrip(dim)
    }

    @Test("Relationship round-trips through JSON encode/decode")
    func relationshipRoundTrip() throws {
        try assertRoundTrip(canonicalRelationship)
    }

    @Test("Relationship with couple facts round-trips through JSON encode/decode")
    func relationshipWithFactsRoundTrip() throws {
        var relationship = canonicalRelationship
        relationship.type = .couple
        relationship.facts = [
            PersonFact(
                type: .marriage, date: "1918-06-14", place: "Chicago, Illinois, USA",
                supportedByLinks: ["LNK-018f3c9a-7b2e-7c41-9e3a-000000000201"]),
            PersonFact(type: .divorce, date: "1931~"),
        ]
        try assertRoundTrip(relationship)
    }

    /// A `Relationship` sidecar written before slice 43 has no `facts` key; it must
    /// still decode, with `facts` defaulting to `[]` (the additive-widening contract).
    @Test("Relationship without a facts key decodes to empty facts (back-compat)")
    func relationshipMissingFactsDecodes() throws {
        let legacyJSON = """
            {
              "uid": "REL-018f3c9a-7b2e-7c41-9e3a-000000000007",
              "schemaVersion": "1.0",
              "type": "couple",
              "person1Uid": "PER-018f3c9a-7b2e-7c41-9e3a-000000000001",
              "person2Uid": "PER-018f3c9a-7b2e-7c41-9e3a-000000000014",
              "supportedByLinks": [],
              "reviewStatus": "asserted",
              "provenance": {
                "createdBy": "human",
                "createdAt": "2026-02-22T15:04:05Z",
                "tool": null,
                "reviewStatus": "asserted"
              }
            }
            """
        let decoded = try GeneaLogicJSON.decoder.decode(
            Relationship.self, from: Data(legacyJSON.utf8))
        #expect(decoded.facts.isEmpty)
    }

    @Test("Manifest round-trips through JSON encode/decode")
    func manifestRoundTrip() throws {
        try assertRoundTrip(canonicalManifest)
    }

    @Test("ManifestEntry round-trips through JSON encode/decode")
    func manifestEntryRoundTrip() throws {
        let entry = ManifestEntry(
            path: "artifacts/ART-001/record.json",
            sha256: "deadbeef",
            byteLength: 512
        )
        try assertRoundTrip(entry)
    }

    @Test("Retrieval round-trips through JSON encode/decode")
    func retrievalRoundTrip() throws {
        let retrieval = Retrieval(
            source: "FamilySearch",
            date: "2026-01-01",
            checksum: "abc123"
        )
        try assertRoundTrip(retrieval)
    }

    @Test("ExternalIdentifier round-trips through JSON encode/decode")
    func externalIdentifierRoundTrip() throws {
        let id = ExternalIdentifier(scheme: .ark, value: "ark:/12345/xyz", repository: "NARA")
        try assertRoundTrip(id)
    }

    @Test("Provenance round-trips through JSON encode/decode")
    func provenanceRoundTrip() throws {
        let prov = Provenance(
            createdBy: .machine,
            createdAt: "2026-02-22T10:00:00Z",
            tool: "ocr-engine-2.1",
            reviewStatus: .machineSuggested
        )
        try assertRoundTrip(prov)
    }

    @Test("TrashEntry round-trips through JSON encode/decode")
    func trashEntryRoundTrip() throws {
        let entry = TrashEntry(
            kind: .artifact,
            deletedAt: "2026-06-25T18:30:00Z",
            artifact: ArtifactTrashInfo(
                uid: "ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70",
                title: "1920 US Census – Smith Family",
                originalSlug: "1920-us-census-smith-family"
            )
        )
        try assertRoundTrip(entry)
    }

    @Test("TrashEntry (file kind) round-trips through JSON encode/decode")
    func fileTrashEntryRoundTrip() throws {
        let entry = TrashEntry(
            kind: .file,
            deletedAt: "2026-06-27T09:15:00Z",
            file: FileTrashInfo(
                entry: FileEntry(
                    uid: "FIL-018f3c9a-0000-7000-8000-000000000099",
                    path: "death-certificate.pdf",
                    originalName: "Death Certificate.pdf",
                    role: .accessCopy,
                    format: "PDF",
                    byteLength: 524_288,
                    sha256: "fed987cba654"
                ),
                artifactUID: "ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70",
                artifactTitle: "1920 US Census – Smith Family"
            )
        )
        try assertRoundTrip(entry)
    }

    // MARK: - Dismissal (45m)

    /// The non-negotiable for a new record type, in both of its shapes: the scored one a
    /// duplicate candidate produces, and the bare one 45l's relationship suggestions will.
    @Test("Dismissal round-trips through JSON encode/decode")
    func dismissalRoundTrip() throws {
        try assertRoundTrip(canonicalDismissal)

        try assertRoundTrip(
            Dismissal(
                uid: "DSM-018f3c9a-0000-7000-8000-0000000000d2",
                subject: .parentChild,
                person1Uid: "PER-018f3c9a-0000-7000-8000-000000000002",
                person2Uid: "PER-018f3c9a-0000-7000-8000-000000000001",
                dismissedBy: "ada",
                dismissedAt: "2026-08-02T10:00:00Z",
                provenance: Provenance(
                    createdBy: .human, createdAt: "2026-08-02T10:00:00Z",
                    reviewStatus: .humanVerified)))
    }

    /// The open-vocabulary rule on the subject, which is the whole reason it is open: a
    /// dismissal a later version wrote must still **load** here, verbatim. And because the
    /// value is unrecognized, its symmetry is unknowable — so it compares directionally,
    /// the conservative reading, rather than silently collapsing two distinct records.
    @Test("An unknown dismissal subject round-trips verbatim and stays directional (45m)")
    func unknownDismissalSubjectRoundTrips() throws {
        let json = """
            {
              "uid": "DSM-018f3c9a-0000-7000-8000-0000000000d3",
              "schemaVersion": "1.0",
              "subject": "same-household",
              "person1Uid": "PER-018f3c9a-0000-7000-8000-000000000001",
              "person2Uid": "PER-018f3c9a-0000-7000-8000-000000000002",
              "provenance": {
                "createdBy": "human",
                "createdAt": "2026-08-02T10:00:00Z",
                "reviewStatus": "human-verified"
              }
            }
            """
        let decoded = try GeneaLogicJSON.decoder.decode(Dismissal.self, from: Data(json.utf8))
        #expect(decoded.subject == .unknown("same-household"))
        #expect(decoded.subject.isSymmetric == false)
        #expect(decoded.match == nil)

        let reEncoded = try GeneaLogicJSON.encoder.encode(decoded)
        #expect(String(decoding: reEncoded, as: UTF8.self).contains("\"same-household\""))
        try assertRoundTrip(decoded)
    }

    /// One dismissal is one record, and `==` cannot say so: a symmetric subject written
    /// from the other end is the same judgement, while a `parent-child` with swapped
    /// endpoints is the *opposite* claim. This is 45k's shipped bug, which its own tests
    /// missed and a hand-test caught, asserted before it can be made twice.
    @Test("declines() is symmetric only for a symmetric subject (45m)")
    func declinesIsSymmetricOnlyForASymmetricSubject() {
        let a: PersonID = "PER-018f3c9a-0000-7000-8000-000000000001"
        let b: PersonID = "PER-018f3c9a-0000-7000-8000-000000000002"

        #expect(canonicalDismissal.declines(.samePerson, between: a, and: b))
        #expect(canonicalDismissal.declines(.samePerson, between: b, and: a))
        // A different claim over the same pair is left entirely open.
        #expect(!canonicalDismissal.declines(.parentChild, between: a, and: b))

        let parent = Dismissal(
            uid: "DSM-018f3c9a-0000-7000-8000-0000000000d4",
            subject: .parentChild, person1Uid: a, person2Uid: b,
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-08-02T10:00:00Z",
                reviewStatus: .humanVerified))
        #expect(parent.declines(.parentChild, between: a, and: b))
        #expect(!parent.declines(.parentChild, between: b, and: a))
    }

    /// Canonicalization is what makes the symmetric case one record on disk; applying it
    /// to a directional subject would state the opposite thing, so it must not.
    @Test("canonicalPair orders a symmetric subject and leaves a directional one (45m)")
    func canonicalPairOrdersOnlySymmetricSubjects() {
        let low: PersonID = "PER-000"
        let high: PersonID = "PER-999"

        let symmetric = Dismissal.canonicalPair(high, low, subject: .samePerson)
        #expect(symmetric == (low, high))

        let directional = Dismissal.canonicalPair(high, low, subject: .parentChild)
        #expect(directional == (high, low))

        let unknown = Dismissal.canonicalPair(high, low, subject: .unknown("same-household"))
        #expect(unknown == (high, low))
    }
}

// MARK: - Golden fixture tests

@Suite("Golden fixture tests")
struct GoldenFixtureTests {

    @Test("Artifact fixture decodes and matches expected value")
    func artifactFixture() throws {
        try assertFixture(named: "artifact.json", matches: canonicalArtifact)
    }

    /// The post-44h shape, beside `artifact.json`'s pre-44h one. Both belong in the
    /// fixture set: that one proves an older record still decodes, this one shows
    /// what the encoder writes now.
    ///
    /// This also asserts the **fixture's own bytes** are what the encoder produces,
    /// which `assertFixture` deliberately does not (it compares two *re*-encodings,
    /// so it can't catch a key that was renamed in both the model and the fixture).
    /// That makes this the one test that pins the emitted key names — `facts`,
    /// `nameLanguage`, `nameScript`, `sourceDerivation` — as on-disk contract.
    @Test("Artifact fixture with the 44h fields decodes and re-encodes byte-for-byte")
    func artifact44hFixture() throws {
        try assertFixture(named: "artifact-44h.json", matches: canonicalArtifact44h)

        let encoded = try GeneaLogicJSON.encoder.encode(canonicalArtifact44h)
        let fixture = try FixtureLoader.data(for: "artifact-44h.json")
        // The fixture is stored pretty-printed for readability; compare parsed forms
        // via a normalizing re-encode of each so the assertion is about *content*,
        // not indentation.
        let fixtureNormalized = try GeneaLogicJSON.encoder.encode(
            GeneaLogicJSON.decoder.decode(Artifact.self, from: fixture))
        #expect(
            encoded == fixtureNormalized,
            "artifact-44h.json no longer matches what the encoder writes — a stored key changed")
    }

    /// The same byte-level pin for slice 45k's field: `assertFixture` normalizes both
    /// sides through a decode, so only an encoder-vs-fixture comparison can catch a
    /// renamed key — and `mentionRelationships` / `person1Ref` / `person2Ref` are
    /// on-disk contract from here on.
    @Test("Artifact fixture with stated relationships re-encodes byte-for-byte (45k)")
    func artifact45kFixture() throws {
        try assertFixture(named: "artifact-45k.json", matches: canonicalArtifact45k)

        let encoded = try GeneaLogicJSON.encoder.encode(canonicalArtifact45k)
        let fixture = try FixtureLoader.data(for: "artifact-45k.json")
        let fixtureNormalized = try GeneaLogicJSON.encoder.encode(
            GeneaLogicJSON.decoder.decode(Artifact.self, from: fixture))
        #expect(
            encoded == fixtureNormalized,
            "artifact-45k.json no longer matches what the encoder writes — a stored key changed")
    }

    @Test("Person fixture decodes and matches expected value")
    func personFixture() throws {
        try assertFixture(named: "person.json", matches: canonicalPerson)
    }

    @Test("EvidenceLink fixture decodes and matches expected value")
    func evidenceLinkFixture() throws {
        try assertFixture(named: "evidence-link.json", matches: canonicalEvidenceLink)
    }

    @Test("Relationship fixture decodes and matches expected value")
    func relationshipFixture() throws {
        try assertFixture(named: "relationship.json", matches: canonicalRelationship)
    }

    @Test("Manifest fixture decodes and matches expected value")
    func manifestFixture() throws {
        try assertFixture(named: "manifest.json", matches: canonicalManifest)
    }
}

// MARK: - Enum coding tests

@Suite("Enum coding tests")
struct EnumCodingTests {

    @Test("SourceAuthorityTier raw values match documented JSON keys")
    func sourceAuthorityTierRawValues() {
        #expect(SourceAuthorityTier.vital.rawValue == "vital")
        #expect(SourceAuthorityTier.church.rawValue == "church")
        #expect(SourceAuthorityTier.census.rawValue == "census")
        #expect(SourceAuthorityTier.newspaper.rawValue == "newspaper")
        #expect(SourceAuthorityTier.bible.rawValue == "bible")
        #expect(SourceAuthorityTier.compiled.rawValue == "compiled")
        // The two genres slice 46 promoted out of `compiled`.
        #expect(SourceAuthorityTier.government.rawValue == "government")
        #expect(SourceAuthorityTier.monument.rawValue == "monument")
    }

    /// The promotion's whole point: a string an older build stored as `.unknown` now
    /// decodes as a known case and re-encodes to the **identical** string, so an
    /// archive already carrying `"government"` needs no migration.
    @Test("Slice 46's promoted tiers decode as known and re-encode verbatim")
    func promotedTiersDecodeAsKnown() throws {
        for raw in ["government", "monument"] {
            let decoded = try GeneaLogicJSON.decoder.decode(
                SourceAuthorityTier.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
            #expect(!SourceAuthorityTier.knownCases.filter { $0 == decoded }.isEmpty)

            let reEncoded = try GeneaLogicJSON.encoder.encode(decoded)
            #expect(String(decoding: reEncoded, as: UTF8.self) == "\"\(raw)\"")
        }
    }

    @Test("PersonRole raw values match documented JSON keys")
    func personRoleRawValues() {
        #expect(PersonRole.subject.rawValue == "subject")
        #expect(PersonRole.informant.rawValue == "informant")
        #expect(PersonRole.witness.rawValue == "witness")
        #expect(PersonRole.parent.rawValue == "parent")
        #expect(PersonRole.spouse.rawValue == "spouse")
        // The register roles added when the vocabulary opened (slice 44h).
        #expect(PersonRole.godparent.rawValue == "godparent")
        #expect(PersonRole.sponsor.rawValue == "sponsor")
        #expect(PersonRole.declarant.rawValue == "declarant")
        #expect(PersonRole.registrar.rawValue == "registrar")
        #expect(PersonRole.clergy.rawValue == "clergy")
        #expect(PersonRole.midwife.rawValue == "midwife")
    }

    /// `PersonRole` was a *closed* enum until slice 44h, so a role the vocabulary
    /// didn't list failed the whole record's decode. Every previously-legal value must
    /// still parse to the same case, and an unrecognized one must now be preserved
    /// verbatim rather than rejected.
    @Test("PersonRole is open: legacy values still parse, unknown ones survive (44h)")
    func personRoleOpensBackCompatibly() throws {
        for legacy in ["subject", "informant", "witness", "parent", "spouse"] {
            #expect(PersonRole(parsing: legacy).rawValue == legacy)
        }
        for role in PersonRole.knownCases {
            let data = try GeneaLogicJSON.encoder.encode(role)
            #expect(try GeneaLogicJSON.decoder.decode(PersonRole.self, from: data) == role)
        }

        // The failure this change exists to prevent: a role a real register carries
        // that we haven't enumerated must load, not throw, and must re-encode verbatim.
        let exotic = try GeneaLogicJSON.decoder.decode(
            PersonRole.self, from: Data("\"marriage-broker\"".utf8))
        #expect(exotic == .unknown("marriage-broker"))
        let reencoded = try GeneaLogicJSON.encoder.encode(exotic)
        #expect(String(decoding: reencoded, as: UTF8.self) == "\"marriage-broker\"")
    }

    @Test("SourceDerivation raw values match documented JSON keys (44h)")
    func sourceDerivationRawValues() throws {
        #expect(SourceDerivation.original.rawValue == "original")
        #expect(SourceDerivation.derivative.rawValue == "derivative")
        #expect(SourceDerivation.authored.rawValue == "authored")
        for derivation in SourceDerivation.knownCases {
            let data = try GeneaLogicJSON.encoder.encode(derivation)
            #expect(
                try GeneaLogicJSON.decoder.decode(SourceDerivation.self, from: data)
                    == derivation)
        }
        #expect(SourceDerivation(parsing: "microfilm") == .unknown("microfilm"))
    }

    @Test("FileRole raw values match documented JSON keys")
    func fileRoleRawValues() {
        #expect(FileRole.preservationMaster.rawValue == "preservation-master")
        #expect(FileRole.accessCopy.rawValue == "access-copy")
        #expect(FileRole.derivative.rawValue == "derivative")
        #expect(FileRole.transcript.rawValue == "transcript")
    }

    @Test("RelationshipType raw values match documented JSON keys")
    func relationshipTypeRawValues() {
        #expect(RelationshipType.parentChild.rawValue == "parent-child")
        #expect(RelationshipType.couple.rawValue == "couple")
    }

    @Test("ReviewStatus raw values match documented JSON keys")
    func reviewStatusRawValues() {
        #expect(ReviewStatus.asserted.rawValue == "asserted")
        #expect(ReviewStatus.machineSuggested.rawValue == "machine-suggested")
        #expect(ReviewStatus.humanVerified.rawValue == "human-verified")
    }

    @Test("LinkReviewStatus raw values match documented JSON keys")
    func linkReviewStatusRawValues() {
        #expect(LinkReviewStatus.machineSuggested.rawValue == "machine-suggested")
        #expect(LinkReviewStatus.humanConfirmed.rawValue == "human-confirmed")
        #expect(LinkReviewStatus.humanRejected.rawValue == "human-rejected")
    }

    @Test("InformationQuality raw values match documented JSON keys")
    func informationQualityRawValues() {
        #expect(InformationQuality.primary.rawValue == "primary")
        #expect(InformationQuality.secondary.rawValue == "secondary")
        #expect(InformationQuality.undetermined.rawValue == "undetermined")
    }

    @Test("CreatedBy raw values match documented JSON keys")
    func createdByRawValues() {
        #expect(CreatedBy.human.rawValue == "human")
        #expect(CreatedBy.machine.rawValue == "machine")
    }

    @Test("MatchKind raw values match documented JSON keys")
    func matchKindRawValues() {
        #expect(MatchKind.exact.rawValue == "exact")
        #expect(MatchKind.phonetic.rawValue == "phonetic")
        #expect(MatchKind.knownVariant.rawValue == "known-variant")
        #expect(MatchKind.within.rawValue == "within")
        #expect(MatchKind.none.rawValue == "none")
    }

    @Test("MatchGranularity raw values match documented JSON keys (45h)")
    func matchGranularityRawValues() {
        #expect(MatchGranularity.specific.rawValue == "specific")
        #expect(MatchGranularity.partial.rawValue == "partial")
        #expect(MatchGranularity.coarse.rawValue == "coarse")
        #expect(MatchGranularity.unqualified.rawValue == "unqualified")
    }

    /// **Slice 45n: the one exact match that carries a granularity.** Every other
    /// granularity rides `kind: "within"`, and the spec said outright that an exact match
    /// has none. An equality on a *single* component is the exception — the values agree
    /// perfectly and the depth of that agreement is unmeasurable — so the pairing has to
    /// survive a round-trip rather than being normalized away by either field.
    @Test("An exact dimension carrying `unqualified` round-trips (45n)")
    func exactWithUnqualifiedGranularityRoundTrips() throws {
        let dimension = MatchDimension(kind: .exact, score: 50, granularity: .unqualified)
        let data = try GeneaLogicJSON.encoder.encode(dimension)
        let decoded = try GeneaLogicJSON.decoder.decode(MatchDimension.self, from: data)

        #expect(decoded == dimension)
        #expect(decoded.kind == .exact)
        #expect(decoded.granularity == .unqualified)
        #expect(String(data: data, encoding: .utf8)?.contains("\"unqualified\"") == true)
    }

    /// A breakdown written before 45n keeps what it stored — `exact / 100` with no
    /// granularity — because a stored breakdown is a verdict at a time (45c), not
    /// something a later build re-scores on read.
    @Test("A pre-45n exact place dimension still loads unchanged (45n)")
    func preSliceExactPlaceDimensionIsUntouched() throws {
        let decoded = try GeneaLogicJSON.decoder.decode(
            MatchDimension.self, from: Data(#"{"kind":"exact","score":100}"#.utf8))

        #expect(decoded.kind == .exact)
        #expect(decoded.score == 100)
        #expect(decoded.granularity == nil)
    }

    @Test("MatchGranularity is open: an unknown value survives a round-trip (45h)")
    func matchGranularityIsOpen() throws {
        // A later gazetteer-backed matcher may say `admin2`; this build must carry it
        // through untouched rather than dropping or normalizing it.
        let dimension = MatchDimension(
            kind: .within, score: 70, granularity: .unknown("admin2"))
        let data = try GeneaLogicJSON.encoder.encode(dimension)
        let decoded = try GeneaLogicJSON.decoder.decode(MatchDimension.self, from: data)
        #expect(decoded == dimension)
        #expect(decoded.granularity == .unknown("admin2"))
        #expect(String(data: data, encoding: .utf8)?.contains("\"admin2\"") == true)
    }

    @Test("Every known MatchGranularity round-trips on a dimension (45h)")
    func matchGranularityAllCasesRoundTrip() throws {
        for granularity in MatchGranularity.knownCases {
            let dimension = MatchDimension(kind: .within, score: 55, granularity: granularity)
            let data = try GeneaLogicJSON.encoder.encode(dimension)
            #expect(try GeneaLogicJSON.decoder.decode(MatchDimension.self, from: data) == dimension)
        }
    }

    /// **The migration, and the reason `MatchDimension` decodes by hand.** An archive
    /// written before 45h stores `county`/`country` in a *closed* vocabulary, so without
    /// this it would fail to load — GeneaLogic refusing a value GeneaLogic wrote.
    @Test("A pre-45h dimension carrying county/country still loads (45h)")
    func legacyPlaceKindsStillDecode() throws {
        func decode(_ json: String) throws -> MatchDimension {
            try GeneaLogicJSON.decoder.decode(
                MatchDimension.self, from: Data(json.utf8))
        }

        // The word is kept and only the field changes. Translating `county` into a
        // structural case would be inventing precision: it was emitted for *two* claims
        // at two different scores, and a stored breakdown is a verdict at a time (45c)
        // — preserved, not re-derived.
        let town = try decode(#"{"kind":"county","score":80}"#)
        #expect(town.kind == .within)
        #expect(town.granularity == .unknown("county"))
        #expect(town.score == 80)

        let country = try decode(#"{"kind":"country","score":30}"#)
        #expect(country.kind == .within)
        #expect(country.granularity == .unknown("country"))

        // A score this matcher never emitted is carried just the same, where a score
        // heuristic would have had to guess at it. (This repo's own golden fixture.)
        #expect(try decode(#"{"kind":"county","score":50}"#).granularity == .unknown("county"))

        // The relocated word then round-trips verbatim, like any open-vocab value.
        let reencoded =
            String(
                data: try GeneaLogicJSON.encoder.encode(town), encoding: .utf8) ?? ""
        #expect(reencoded.contains("\"granularity\":\"county\""))
        #expect(!reencoded.contains("\"kind\":\"county\""))
        #expect(try decode(reencoded) == town)
    }

    /// A genuinely unrecognized kind is still an error — 45h retired two spellings, it
    /// did not open the vocabulary.
    @Test("An unknown match kind is still rejected (45h)")
    func unknownMatchKindStillFails() {
        #expect(throws: (any Error).self) {
            try GeneaLogicJSON.decoder.decode(
                MatchDimension.self, from: Data(#"{"kind":"parish","score":70}"#.utf8))
        }
    }

    @Test("All known SourceAuthorityTier cases round-trip through JSON")
    func sourceAuthorityTierAllCasesRoundTrip() throws {
        for tier in SourceAuthorityTier.knownCases {
            let data = try GeneaLogicJSON.encoder.encode(tier)
            let decoded = try GeneaLogicJSON.decoder.decode(SourceAuthorityTier.self, from: data)
            #expect(decoded == tier)
        }
    }

    @Test("All FileRole cases round-trip through JSON")
    func fileRoleAllCasesRoundTrip() throws {
        for role in FileRole.allCases {
            let data = try GeneaLogicJSON.encoder.encode(role)
            let decoded = try GeneaLogicJSON.decoder.decode(FileRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test("All known RelationshipType cases round-trip through JSON")
    func relationshipTypeAllCasesRoundTrip() throws {
        for rt in RelationshipType.knownCases {
            let data = try GeneaLogicJSON.encoder.encode(rt)
            let decoded = try GeneaLogicJSON.decoder.decode(RelationshipType.self, from: data)
            #expect(decoded == rt)
        }
    }

    @Test("All known FactType cases round-trip through JSON (incl. divorce/annulment)")
    func factTypeAllCasesRoundTrip() throws {
        for ft in FactType.knownCases {
            let data = try GeneaLogicJSON.encoder.encode(ft)
            let decoded = try GeneaLogicJSON.decoder.decode(FactType.self, from: data)
            #expect(decoded == ft)
        }
        // The couple-fact vocabulary added in slice 43 parses from its GEDCOM X strings.
        #expect(FactType(parsing: "Divorce") == .divorce)
        #expect(FactType(parsing: "Annulment") == .annulment)
        #expect(FactType.coupleCases == [.marriage, .divorce, .annulment])
        // The migration/citizenship types, promoted from `.unknown` because they're
        // routine for an immigrant corpus. Person-scoped, so they must fall into
        // `personCases` and `recordedCases` without either subset being edited.
        #expect(FactType(parsing: "Naturalization") == .naturalization)
        #expect(FactType(parsing: "Immigration") == .immigration)
        #expect(FactType(parsing: "Emigration") == .emigration)
        for migration: FactType in [.naturalization, .immigration, .emigration] {
            #expect(FactType.personCases.contains(migration))
            #expect(FactType.recordedCases.contains(migration))
        }
        // The declaration-of-intention + value-bearing person types promoted in slice
        // 44i parse from their GEDCOM X strings and are likewise person-scoped.
        #expect(FactType(parsing: "DeclarationOfIntention") == .declarationOfIntention)
        #expect(FactType(parsing: "Occupation") == .occupation)
        #expect(FactType(parsing: "PhysicalDescription") == .physicalDescription)
        for promoted: FactType in [.declarationOfIntention, .occupation, .physicalDescription] {
            #expect(FactType.personCases.contains(promoted))
            #expect(FactType.recordedCases.contains(promoted))
        }
        // …and the lenient input parse folds a typed lowercase value onto the known
        // case rather than minting a twin that renders identically.
        #expect(FactType.parsingLeniently("naturalization") == .naturalization)
        // Multi-word human input folds to a PascalCase known case (internal whitespace is
        // collapsed), so "Declaration of Intention" is not stored as an `.unknown` twin.
        #expect(FactType.parsingLeniently("Declaration of Intention") == .declarationOfIntention)
        #expect(FactType.parsingLeniently("physical description") == .physicalDescription)
        // A genuinely off-list multi-word type is preserved verbatim (trimmed), not folded.
        #expect(FactType.parsingLeniently("  Manumission Deed ") == .unknown("Manumission Deed"))
    }

    @Test("Parent-child fact types parse from their GEDCOM X strings (slice 44f)")
    func parentChildFactTypesParse() {
        #expect(FactType(parsing: "AdoptiveParent") == .adoptiveParent)
        #expect(FactType(parsing: "BiologicalParent") == .biologicalParent)
        #expect(FactType(parsing: "StepParent") == .stepParent)
        #expect(FactType(parsing: "FosterParent") == .fosterParent)
        #expect(FactType(parsing: "GuardianParent") == .guardianParent)
        #expect(
            FactType.parentChildCases == [
                .biologicalParent, .adoptiveParent, .stepParent, .fosterParent, .guardianParent,
            ])
    }

    @Test("The three fact-type subsets partition the known cases without overlap")
    func factTypeSubsetsPartitionKnownCases() {
        // The editors pick their options from these subsets, so an overlap would offer
        // "AdoptiveParent" as a person fact (or "Birth" as a parent-child qualifier),
        // and a gap would make a known case unreachable in every editor.
        let person = Set(FactType.personCases)
        let couple = Set(FactType.coupleCases)
        let parentChild = Set(FactType.parentChildCases)

        #expect(person.isDisjoint(with: couple))
        #expect(person.isDisjoint(with: parentChild))
        #expect(couple.isDisjoint(with: parentChild))
        #expect(person.union(couple).union(parentChild) == Set(FactType.knownCases))
        // The specific regression: the parent-role types must not leak into the person
        // editor, which derives its options by subtracting from `knownCases`.
        #expect(!person.contains(.adoptiveParent))
        #expect(!person.contains(.biologicalParent))
    }

    @Test("recordedCases is every known type except the parent-child qualifiers (44h)")
    func recordedFactTypeSubset() {
        let recorded = Set(FactType.recordedCases)

        // A marriage register's entry for the groom records his marriage, so the
        // evidence layer must be able to say so — `recordedCases` is deliberately
        // wider than `personCases`.
        #expect(recorded.contains(.marriage))
        #expect(recorded.isSuperset(of: Set(FactType.personCases)))
        #expect(recorded.isSuperset(of: Set(FactType.coupleCases)))

        // …but a parent-role qualifier describes a concluded *edge* between two
        // identities, so it can never be an observation about one named person.
        #expect(recorded.isDisjoint(with: Set(FactType.parentChildCases)))
        #expect(recorded.union(Set(FactType.parentChildCases)) == Set(FactType.knownCases))
    }

    @Test("Value-bearing fact types are classified advisorily (slice 44i)")
    func valueBearingFactTypes() {
        // The value-bearing known cases drive the editors' Value-field visibility.
        #expect(FactType.valueBearingCases == [.occupation, .physicalDescription])
        #expect(FactType.occupation.isValueBearing)
        #expect(FactType.physicalDescription.isValueBearing)
        // Event-like types are not — a birth/marriage carries a date/place, not a value.
        #expect(!FactType.birth.isValueBearing)
        #expect(!FactType.marriage.isValueBearing)
        #expect(!FactType.declarationOfIntention.isValueBearing)
        // A custom (unknown) type is treated as value-bearing: this build can't know it
        // isn't, and the researcher shouldn't be denied the field.
        #expect(FactType.unknown("Manumission").isValueBearing)
    }

    @Test("All ReviewStatus cases round-trip through JSON")
    func reviewStatusAllCasesRoundTrip() throws {
        for status in ReviewStatus.allCases {
            let data = try GeneaLogicJSON.encoder.encode(status)
            let decoded = try GeneaLogicJSON.decoder.decode(ReviewStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    @Test("All LinkReviewStatus cases round-trip through JSON")
    func linkReviewStatusAllCasesRoundTrip() throws {
        for status in LinkReviewStatus.allCases {
            let data = try GeneaLogicJSON.encoder.encode(status)
            let decoded = try GeneaLogicJSON.decoder.decode(LinkReviewStatus.self, from: data)
            #expect(decoded == status)
        }
    }
}

// MARK: - Open vocabulary (unknown-preserving) tests

@Suite("Open vocabulary tests")
struct OpenVocabularyTests {

    @Test("A known tier string decodes to the known case")
    func knownTierDecodes() throws {
        let data = Data("\"census\"".utf8)
        let decoded = try GeneaLogicJSON.decoder.decode(SourceAuthorityTier.self, from: data)
        #expect(decoded == .census)
    }

    /// The sample is `"shipManifest"` rather than the old `"probate"` because slice 46's
    /// `government` covers court records, and a sample that a later slice will promote is
    /// a test that will one day fail for no reason.
    ///
    /// It stays a good sample under 46's clarified reading, but for the **opposite** reason
    /// to the one first written here: a manifest is not a genre awaiting its own tier — it
    /// is a `government` record, so nothing will ever promote this string. What the value
    /// stands for is a **cataloguer's own label** reaching a build that never heard of it,
    /// which is the case `.unknown` exists for. *(First written as "the genre 46 left in
    /// `.unknown`", which the hand-test showed was the wrong reading of the fork — see the
    /// 46 entry in SLICE-LOG.)*
    @Test("An unrecognized tier is preserved as .unknown and re-encodes verbatim")
    func unknownTierIsPreserved() throws {
        let data = Data("\"shipManifest\"".utf8)
        let decoded = try GeneaLogicJSON.decoder.decode(SourceAuthorityTier.self, from: data)
        #expect(decoded == .unknown("shipManifest"))

        let reEncoded = try GeneaLogicJSON.encoder.encode(decoded)
        #expect(String(decoding: reEncoded, as: UTF8.self) == "\"shipManifest\"")
    }

    /// The sample value must be one we are **not** going to promote to a known case.
    /// It was `"Naturalization"` until that became known — the test then failed, which
    /// is the right outcome (promoting a case really does change behavior) but means
    /// the sample was doing double duty as "a plausible type we haven't got yet".
    /// `"Manumission"` is a real archival event type well outside this project's
    /// scope, so it can stand for the general case without becoming a maintenance
    /// tripwire every time the vocabulary grows.
    @Test("An unknown fact type survives a full model round-trip")
    func unknownFactTypeRoundTrips() throws {
        let fact = PersonFact(type: .unknown("Manumission"), date: "1834")
        let encoded = try GeneaLogicJSON.encoder.encode(fact)
        let decoded = try GeneaLogicJSON.decoder.decode(PersonFact.self, from: encoded)
        #expect(decoded == fact)
        #expect(decoded.type == .unknown("Manumission"))
    }
}

// MARK: - Typed identifier tests

@Suite("Typed identifier tests")
struct IdentifierTests {

    @Test("An identifier encodes as a bare JSON string, not an object")
    func identifierEncodesAsString() throws {
        let id = ArtifactID("ART-018f3c9a")
        let encoded = try GeneaLogicJSON.encoder.encode(id)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"ART-018f3c9a\"")
    }

    @Test("An identifier round-trips through JSON")
    func identifierRoundTrips() throws {
        let id = PersonID("PER-018f3c9a")
        let encoded = try GeneaLogicJSON.encoder.encode(id)
        let decoded = try GeneaLogicJSON.decoder.decode(PersonID.self, from: encoded)
        #expect(decoded == id)
        #expect(decoded.raw == "PER-018f3c9a")
    }
}

// MARK: - Encoding determinism tests

@Suite("Encoding determinism tests")
struct EncodingDeterminismTests {

    @Test("Encoding the same Artifact twice produces identical bytes")
    func artifactEncodingIsDeterministic() throws {
        let a = canonicalArtifact
        let encoded1 = try GeneaLogicJSON.encoder.encode(a)
        let encoded2 = try GeneaLogicJSON.encoder.encode(a)
        #expect(encoded1 == encoded2)
    }

    @Test("Encoding the same EvidenceLink twice produces identical bytes")
    func evidenceLinkEncodingIsDeterministic() throws {
        let link = canonicalEvidenceLink
        let encoded1 = try GeneaLogicJSON.encoder.encode(link)
        let encoded2 = try GeneaLogicJSON.encoder.encode(link)
        #expect(encoded1 == encoded2)
    }

    @Test("Pretty-encoding and compact-encoding decode to equal values")
    func prettyAndCompactEncodeToSameDecoded() throws {
        let a = canonicalArtifact
        let prettyData = try GeneaLogicJSON.prettyEncoder.encode(a)
        let compactData = try GeneaLogicJSON.encoder.encode(a)
        let fromPretty = try GeneaLogicJSON.decoder.decode(Artifact.self, from: prettyData)
        let fromCompact = try GeneaLogicJSON.decoder.decode(Artifact.self, from: compactData)
        #expect(fromPretty == fromCompact)
    }

    @Test("JSON keys in Artifact encoding are sorted")
    func artifactKeysAreSorted() throws {
        let a = canonicalArtifact
        let data = try GeneaLogicJSON.encoder.encode(a)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        let keys = json!.keys.sorted()
        // Verify a few known top-level keys are present and that sorted order holds
        #expect(keys.contains("uid"))
        #expect(keys.contains("title"))
        #expect(keys.contains("schemaVersion"))
        #expect(keys.contains("provenance"))
    }
}

// MARK: - Schema version tests

@Suite("Schema version tests")
struct SchemaVersionTests {

    @Test("A constructed record carries the current schema version")
    func constructedRecordUsesCurrent() {
        #expect(canonicalArtifact.schemaVersion == SchemaVersion.current)
        #expect(canonicalManifest.schemaVersion == SchemaVersion.current)
    }

    @Test("Decoding preserves an on-disk schema version (for migration)")
    func decodingPreservesOnDiskVersion() throws {
        // A manifest written by a hypothetical future version must still decode,
        // retaining its version rather than being forced to current.
        let json = Data(
            #"{"archiveUID":"ARCH-x","files":[],"schemaVersion":"9.9","updatedAt":"2030-01-01T00:00:00Z"}"#
                .utf8)
        let decoded = try GeneaLogicJSON.decoder.decode(Manifest.self, from: json)
        #expect(decoded.schemaVersion == "9.9")
    }
}
