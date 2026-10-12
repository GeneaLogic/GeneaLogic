import Foundation
import GeneaLogicModel
import GeneaLogicTestSupport
import Testing

/// Round-trip **properties** over generated values of every persisted type (slice
/// 62) — the counterpart to `RoundTripTests`, which proves the shapes someone
/// thought of. Four properties, each over `PropertyRun.fromEnvironment` iterations:
///
/// 1. `decode(encode(v)) == v`.
/// 2. `encode(decode(encode(v))) == encode(v)`, byte for byte — the property 49's
///    manifest checksums and 58's index blobs rest on.
/// 3. The pretty encoder decodes to the same value.
/// 4. Spec §3: an absent optional key and an explicit `null` decode identically.
///
/// A failure prints the seed and iteration that reproduce it; see `PropertyRun`.
@Suite("Property round-trips") struct PropertyRoundTripTests {

    // MARK: - The properties

    private static func checkRoundTrips<T: Codable & Equatable & Arbitrary>(
        _ type: T.Type, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        PropertyRun.fromEnvironment.forEach { rng, iteration in
            let value = T.arbitrary(&rng)
            // A throw is a failure of this iteration, not of the run: record it with the
            // words that reproduce it and carry on, the same as a mismatch.
            do {
                let encoded = try GeneaLogicJSON.encoder.encode(value)
                let decoded = try GeneaLogicJSON.decoder.decode(T.self, from: encoded)
                #expect(
                    decoded == value,
                    "\(T.self) changed across decode(encode(v)) — \(iteration)",
                    sourceLocation: sourceLocation)

                let reEncoded = try GeneaLogicJSON.encoder.encode(decoded)
                #expect(
                    reEncoded == encoded,
                    "\(T.self) re-encoded to different bytes — \(iteration)",
                    sourceLocation: sourceLocation)

                let pretty = try GeneaLogicJSON.prettyEncoder.encode(value)
                let fromPretty = try GeneaLogicJSON.decoder.decode(T.self, from: pretty)
                #expect(
                    fromPretty == value, "\(T.self) pretty-encoded differently — \(iteration)",
                    sourceLocation: sourceLocation)

                let withNulls = try JSONNulls.injectingNulls(into: encoded)
                let fromNulls = try GeneaLogicJSON.decoder.decode(T.self, from: withNulls)
                #expect(
                    fromNulls == value,
                    "\(T.self) read null differently from absent — \(iteration)",
                    sourceLocation: sourceLocation)
            } catch {
                Issue.record(
                    "\(T.self) threw \(error) — \(iteration)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: - One test per persisted type, so a failure names it

    @Test func artifact() throws { try Self.checkRoundTrips(Artifact.self) }
    @Test func person() throws { try Self.checkRoundTrips(Person.self) }
    @Test func relationship() throws { try Self.checkRoundTrips(Relationship.self) }
    @Test func evidenceLink() throws { try Self.checkRoundTrips(EvidenceLink.self) }
    @Test func dismissal() throws { try Self.checkRoundTrips(Dismissal.self) }
    @Test func manifest() throws { try Self.checkRoundTrips(Manifest.self) }
    @Test func trashEntry() throws { try Self.checkRoundTrips(TrashEntry.self) }

    // The nested value types on their own as well: a failure inside an artifact's
    // mention is easier to read as a `PersonMention` failure, and each is small enough
    // that its own iterations reach corners a parent's short arrays would not.
    @Test func personMention() throws { try Self.checkRoundTrips(PersonMention.self) }
    @Test func recordedFact() throws { try Self.checkRoundTrips(RecordedFact.self) }
    @Test func mentionRelationship() throws {
        try Self.checkRoundTrips(MentionRelationship.self)
    }
    @Test func fileEntry() throws { try Self.checkRoundTrips(FileEntry.self) }
    @Test func event() throws { try Self.checkRoundTrips(Event.self) }
    @Test func location() throws { try Self.checkRoundTrips(Location.self) }
    @Test func retrieval() throws { try Self.checkRoundTrips(Retrieval.self) }
    @Test func externalIdentifier() throws {
        try Self.checkRoundTrips(ExternalIdentifier.self)
    }
    @Test func provenance() throws { try Self.checkRoundTrips(Provenance.self) }
    @Test func personName() throws { try Self.checkRoundTrips(PersonName.self) }
    @Test func personFact() throws { try Self.checkRoundTrips(PersonFact.self) }
    @Test func matchDimension() throws { try Self.checkRoundTrips(MatchDimension.self) }
    @Test func matchBreakdown() throws { try Self.checkRoundTrips(MatchBreakdown.self) }
    @Test func manifestEntry() throws { try Self.checkRoundTrips(ManifestEntry.self) }

    // MARK: - Every hostile string, on its own

    /// The generator only *samples* `Gen.hostileStrings`; this walks the whole list
    /// through a string-bearing record so none is left to chance.
    ///
    /// Compared **scalar by scalar**, not with `==`: Swift string equality is canonical
    /// equivalence, so `"é" == "e\u{301}"` is true and the properties above cannot see
    /// an encoder or decoder that normalizes — which is exactly what the NFC/NFD pair in
    /// the list exists to catch. The format stores what it was given.
    @Test func everyHostileStringRoundTrips() throws {
        for hostile in Gen.hostileStrings {
            let event = Event(type: hostile, date: hostile, location: hostile)
            let encoded = try GeneaLogicJSON.encoder.encode(event)
            let decoded = try GeneaLogicJSON.decoder.decode(Event.self, from: encoded)
            #expect(
                decoded.type.unicodeScalars.elementsEqual(hostile.unicodeScalars),
                "hostile string \(hostile.debugDescription) changed at the scalar level")
        }
    }

    /// Property 4 is only as good as the injection: an `Artifact` with every optional
    /// absent must come back carrying explicit nulls, or the property passes vacuously.
    @Test func nullInjectionActuallyInjects() throws {
        let bare = Artifact(
            uid: "ART-0", title: "t", mediaType: .image,
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-01-01T00:00:00Z",
                reviewStatus: .asserted))
        let encoded = try GeneaLogicJSON.encoder.encode(bare)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("null"))
        let injected = String(
            decoding: try JSONNulls.injectingNulls(into: encoded), as: UTF8.self)
        for key in ["notes", "retrieval", "sourceAuthorityTier", "tool"] {
            #expect(injected.contains("\"\(key)\":null"), "no null injected for \(key)")
        }
    }

    // MARK: - The encoder's own promises

    /// `GeneaLogicJSON` sets `.throw` for non-finite floats. No persisted type has a
    /// floating-point field today, so the property suite cannot reach this; it is
    /// checked directly so the configuration is a test rather than a comment.
    @Test func encoderRejectsNonFiniteFloats() {
        struct Probe: Encodable { let value: Double }
        #expect(throws: EncodingError.self) {
            try GeneaLogicJSON.encoder.encode(Probe(value: .nan))
        }
        #expect(throws: EncodingError.self) {
            try GeneaLogicJSON.encoder.encode(Probe(value: .infinity))
        }
    }
}

// MARK: - Null injection

/// Turns every *absent* optional key into an explicit `null`, so a value can be read
/// back through the spec §3 rule that the two mean the same thing.
///
/// Type-agnostic on purpose: it walks the JSON, and in every object inserts `null` for
/// each name in `optionalKeys` that is not already present. A required key is always
/// present, so it is never touched; a name that is optional in one type and required
/// in another (`date`, `value`, `name`) is therefore safe; and a name the object's
/// type does not have at all is an unknown key, which every decoder ignores.
///
/// The one object it does not descend into is `attributes`, a string map whose keys
/// are data — a `null` there would be a malformed *value*, not an absent field.
enum JSONNulls {
    /// Every optional key across the persisted types. A key missing from this list
    /// costs coverage of that key, never a false failure.
    static let optionalKeys: Set<String> = [
        // Artifact
        "sourceAuthorityTier", "sourceDerivation", "originalFormat", "language",
        "transcript", "retrieval", "notes",
        // Event, Location, Retrieval, ExternalIdentifier, Provenance
        "date", "location", "normalized", "checksum", "repository", "tool",
        // RecordedFact, PersonMention
        "place", "value", "informationQuality", "nameLanguage", "nameScript", "attributes",
        // PersonName, PersonFact, Person
        "given", "surname", "full", "script", "identifierURI",
        // MatchDimension, MatchBreakdown
        "delta", "granularity", "nameAlgo", "birthYear", "birthPlace", "spouseName",
        "parents",
        // EvidenceLink, Dismissal
        "reviewedBy", "reviewedAt", "match", "aggregateConfidence", "dismissedBy",
        "dismissedAt",
        // Manifest, TrashEntry
        "name", "artifact", "file",
    ]

    static func injectingNulls(into json: Data) throws -> Data {
        let tree = try JSONSerialization.jsonObject(with: json)
        let injected = inject(into: tree)
        return try JSONSerialization.data(withJSONObject: injected)
    }

    private static func inject(into node: Any) -> Any {
        switch node {
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in object {
                result[key] = key == "attributes" ? child : inject(into: child)
            }
            for key in optionalKeys where result[key] == nil {
                result[key] = NSNull()
            }
            return result
        case let array as [Any]:
            return array.map(inject(into:))
        default:
            return node
        }
    }
}
