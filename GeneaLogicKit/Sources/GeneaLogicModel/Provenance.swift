/// Provenance metadata attached to every record and assertion.
///
/// Tracks who (human vs. machine) created the assertion and its review state.
/// ARCHITECTURE.md §4.2 shows this embedded in `Artifact`, `Person`, `EvidenceLink`,
/// and `Relationship`.
///
/// NOTE (date representation): `createdAt` is a `String` in ISO 8601 format,
/// not `Foundation.Date`. Genealogical dates are frequently partial or approximate;
/// keeping timestamps as `String` avoids silent precision loss and round-trip
/// differences introduced by `Date` ↔ JSON encoding (which requires a specific
/// `dateDecodingStrategy`). Flagged for Opus review.
public struct Provenance: Codable, Sendable, Equatable {
    /// Who created this record: `.human` or `.machine`.
    public var createdBy: CreatedBy

    /// ISO 8601 timestamp of creation. Stored as `String` — see date note above.
    public var createdAt: String

    /// Populated when `createdBy == .machine`; identifies the model/tool version.
    public var tool: String?

    /// Human-review state of this assertion.
    public var reviewStatus: ReviewStatus

    public init(
        createdBy: CreatedBy,
        createdAt: String,
        tool: String? = nil,
        reviewStatus: ReviewStatus
    ) {
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.tool = tool
        self.reviewStatus = reviewStatus
    }
}
