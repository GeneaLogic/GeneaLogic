/// A location entry within an artifact's `locations` array.
///
/// Captures a place name exactly as it appears in the source document,
/// with an optional normalized form for cross-reference.
///
/// Documented in `Artifact.locations[]` (ARCHITECTURE.md §4.2).
///
/// NOTE: The doc shows `"normalized": null` as optional. Both fields are modeled
/// as `String?` so that a location can be recorded without a normalized form.
/// Flagged for Opus review — `normalized` might evolve into a structured type
/// (e.g. a Wikidata QID or a lat/lon pair) in a later phase.
public struct Location: Codable, Sendable, Hashable {
    /// The place name exactly as it appears in the source record.
    public var asRecorded: String

    /// A normalized / disambiguated form of the place name, or `nil` if not yet resolved.
    public var normalized: String?

    public init(
        asRecorded: String,
        normalized: String? = nil
    ) {
        self.asRecorded = asRecorded
        self.normalized = normalized
    }
}
