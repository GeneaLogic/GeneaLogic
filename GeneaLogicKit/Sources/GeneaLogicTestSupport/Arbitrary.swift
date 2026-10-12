import GeneaLogicModel

/// A persisted model type that can generate an arbitrary instance of itself from a
/// seeded generator (slice 62, fork c).
///
/// Every type the archive writes to disk conforms here — the record types with their
/// own sidecar, the value types nested inside them, `Manifest`, and `TrashEntry`.
/// Types that are never persisted (`EmbeddedMetadata` and the `GeneaLogicMatch` views)
/// deliberately do not: a round-trip property over a type nothing writes proves
/// nothing about the format.
///
/// Values go through each type's **public initializer**, so a generated record is one
/// the engine could have constructed — `schemaVersion` is stamped by the initializer,
/// never drawn — and any field the initializer cannot set is a field the property
/// cannot vary. Where a field is a vocabulary, `Gen.open`/`Gen.closed` decide the mix.
public protocol Arbitrary {
    static func arbitrary(_ rng: inout SeededGenerator) -> Self
}

// MARK: - Shared value types

extension Provenance: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Provenance {
        Provenance(
            createdBy: Gen.closed(&rng),
            createdAt: Gen.timestamp(&rng),
            tool: Gen.optional(&rng, Gen.string),
            reviewStatus: Gen.closed(&rng))
    }
}

extension Event: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Event {
        Event(
            type: Gen.string(&rng),
            date: Gen.optional(&rng, Gen.date),
            location: Gen.optional(&rng, Gen.string))
    }
}

extension Location: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Location {
        Location(asRecorded: Gen.string(&rng), normalized: Gen.optional(&rng, Gen.string))
    }
}

extension Retrieval: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Retrieval {
        Retrieval(
            source: Gen.string(&rng),
            date: Gen.timestamp(&rng),
            checksum: Gen.optional(&rng, Gen.sha256))
    }
}

extension ExternalIdentifier: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> ExternalIdentifier {
        ExternalIdentifier(
            scheme: Gen.open(&rng),
            value: Gen.string(&rng),
            repository: Gen.optional(&rng, Gen.string))
    }
}

extension FileEntry: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> FileEntry {
        FileEntry(
            uid: Gen.recordID(&rng, prefix: "FIL"),
            path: Gen.string(&rng),
            originalName: Gen.string(&rng),
            role: Gen.closed(&rng),
            format: Gen.string(&rng),
            byteLength: Gen.byteLength(&rng),
            sha256: Gen.sha256(&rng))
    }
}

// MARK: - Artifact

extension RecordedFact: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> RecordedFact {
        RecordedFact(
            type: Gen.open(&rng),
            date: Gen.optional(&rng, Gen.date),
            place: Gen.optional(&rng, Gen.string),
            value: Gen.optional(&rng, Gen.string),
            informationQuality: Gen.optional(&rng, Gen.closed))
    }
}

extension PersonMention: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> PersonMention {
        PersonMention(
            localRef: Gen.string(&rng),
            nameAsRecorded: Gen.string(&rng),
            role: Gen.open(&rng),
            informationQuality: Gen.closed(&rng),
            facts: Gen.array(&rng, RecordedFact.arbitrary),
            nameLanguage: Gen.optional(&rng, Gen.string),
            nameScript: Gen.optional(&rng, Gen.string),
            attributes: Gen.optional(&rng) { rng in
                // Keys are strings too, and sort under `.sortedKeys` — hostile ones included.
                Dictionary(
                    Gen.array(&rng) { rng in (Gen.string(&rng), Gen.string(&rng)) },
                    uniquingKeysWith: { first, _ in first })
            })
    }
}

extension MentionRelationship: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> MentionRelationship {
        MentionRelationship(
            type: Gen.open(&rng), person1Ref: Gen.string(&rng), person2Ref: Gen.string(&rng))
    }
}

extension Artifact: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Artifact {
        Artifact(
            uid: Gen.recordID(&rng, prefix: "ART"),
            title: Gen.string(&rng),
            mediaType: Gen.open(&rng),
            sourceAuthorityTier: Gen.optional(&rng, Gen.open),
            sourceDerivation: Gen.optional(&rng, Gen.open),
            originalFormat: Gen.optional(&rng, Gen.string),
            language: Gen.optional(&rng, Gen.string),
            events: Gen.array(&rng, Event.arbitrary),
            personsMentioned: Gen.array(&rng, PersonMention.arbitrary),
            mentionRelationships: Gen.array(&rng, MentionRelationship.arbitrary),
            locations: Gen.array(&rng, Location.arbitrary),
            transcript: Gen.optional(&rng, Gen.string),
            files: Gen.array(&rng, FileEntry.arbitrary),
            externalIdentifiers: Gen.array(&rng, ExternalIdentifier.arbitrary),
            retrieval: Gen.optional(&rng, Retrieval.arbitrary),
            provenance: Provenance.arbitrary(&rng),
            tags: Gen.array(&rng, Gen.string),
            notes: Gen.optional(&rng, Gen.string))
    }
}

// MARK: - Conclusions

extension PersonName: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> PersonName {
        PersonName(
            type: Gen.open(&rng),
            given: Gen.optional(&rng, Gen.string),
            surname: Gen.optional(&rng, Gen.string),
            full: Gen.optional(&rng, Gen.string),
            language: Gen.optional(&rng, Gen.string),
            script: Gen.optional(&rng, Gen.string))
    }
}

extension PersonFact: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> PersonFact {
        PersonFact(
            type: Gen.open(&rng),
            date: Gen.optional(&rng, Gen.date),
            place: Gen.optional(&rng, Gen.string),
            value: Gen.optional(&rng, Gen.string),
            supportedByLinks: Gen.array(&rng) { Gen.recordID(&$0, prefix: "LNK") })
    }
}

extension Person: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Person {
        Person(
            uid: Gen.recordID(&rng, prefix: "PER"),
            names: Gen.array(&rng, PersonName.arbitrary),
            facts: Gen.array(&rng, PersonFact.arbitrary),
            identifierURI: Gen.optional(&rng, Gen.string),
            provenance: Provenance.arbitrary(&rng))
    }
}

extension Relationship: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Relationship {
        Relationship(
            uid: Gen.recordID(&rng, prefix: "REL"),
            type: Gen.open(&rng),
            person1Uid: Gen.recordID(&rng, prefix: "PER"),
            person2Uid: Gen.recordID(&rng, prefix: "PER"),
            facts: Gen.array(&rng, PersonFact.arbitrary),
            supportedByLinks: Gen.array(&rng) { Gen.recordID(&$0, prefix: "LNK") },
            reviewStatus: Gen.closed(&rng),
            provenance: Provenance.arbitrary(&rng))
    }
}

extension MatchDimension: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> MatchDimension {
        MatchDimension(
            kind: Gen.closed(&rng),
            score: Gen.score(&rng),
            delta: Gen.optional(&rng, Gen.score),
            granularity: Gen.optional(&rng, Gen.open))
    }
}

extension MatchBreakdown: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> MatchBreakdown {
        MatchBreakdown(
            name: MatchDimension.arbitrary(&rng),
            nameAlgo: Gen.optional(&rng, Gen.string),
            birthYear: Gen.optional(&rng, MatchDimension.arbitrary),
            birthPlace: Gen.optional(&rng, MatchDimension.arbitrary),
            spouseName: Gen.optional(&rng, MatchDimension.arbitrary),
            parents: Gen.optional(&rng, MatchDimension.arbitrary),
            conflicts: Gen.array(&rng, Gen.string))
    }
}

extension EvidenceLink: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> EvidenceLink {
        EvidenceLink(
            uid: Gen.recordID(&rng, prefix: "LNK"),
            artifactUid: Gen.recordID(&rng, prefix: "ART"),
            personMentionRef: Gen.string(&rng),
            personUid: Gen.recordID(&rng, prefix: "PER"),
            match: MatchBreakdown.arbitrary(&rng),
            sourceAuthorityWeight: Gen.score(&rng),
            informationQualityWeight: Gen.score(&rng),
            aggregateConfidence: Gen.score(&rng),
            reviewStatus: Gen.closed(&rng),
            reviewedBy: Gen.optional(&rng, Gen.string),
            reviewedAt: Gen.optional(&rng, Gen.timestamp),
            provenance: Provenance.arbitrary(&rng))
    }
}

extension Dismissal: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Dismissal {
        Dismissal(
            uid: Gen.recordID(&rng, prefix: "DIS"),
            subject: Gen.open(&rng),
            person1Uid: Gen.recordID(&rng, prefix: "PER"),
            person2Uid: Gen.recordID(&rng, prefix: "PER"),
            match: Gen.optional(&rng, MatchBreakdown.arbitrary),
            aggregateConfidence: Gen.optional(&rng, Gen.score),
            dismissedBy: Gen.optional(&rng, Gen.string),
            dismissedAt: Gen.optional(&rng, Gen.timestamp),
            provenance: Provenance.arbitrary(&rng))
    }
}

// MARK: - Manifest and trash

extension ManifestEntry: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> ManifestEntry {
        ManifestEntry(
            path: Gen.string(&rng), sha256: Gen.sha256(&rng), byteLength: Gen.byteLength(&rng))
    }
}

extension Manifest: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> Manifest {
        Manifest(
            archiveUID: Gen.recordID(&rng, prefix: "ARC"),
            name: Gen.optional(&rng, Gen.string),
            updatedAt: Gen.timestamp(&rng),
            files: Gen.array(&rng, max: 8, ManifestEntry.arbitrary))
    }
}

extension ArtifactTrashInfo: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> ArtifactTrashInfo {
        ArtifactTrashInfo(
            uid: Gen.recordID(&rng, prefix: "ART"),
            title: Gen.string(&rng),
            originalSlug: Gen.string(&rng))
    }
}

extension FileTrashInfo: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> FileTrashInfo {
        FileTrashInfo(
            entry: FileEntry.arbitrary(&rng),
            artifactUID: Gen.recordID(&rng, prefix: "ART"),
            artifactTitle: Gen.string(&rng))
    }
}

extension TrashEntry: Arbitrary {
    public static func arbitrary(_ rng: inout SeededGenerator) -> TrashEntry {
        // Both payloads are drawn independently of `kind`: the format stores whatever
        // is there, and the property is about the format, not the engine's invariant.
        TrashEntry(
            kind: Bool.random(using: &rng) ? .artifact : .file,
            deletedAt: Gen.timestamp(&rng),
            artifact: Gen.optional(&rng, ArtifactTrashInfo.arbitrary),
            file: Gen.optional(&rng, FileTrashInfo.arbitrary))
    }
}
