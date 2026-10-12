/// Type-safe record identifiers.
///
/// Every record's `uid` is a type-prefixed UUIDv7 string (ARCHITECTURE.md §4.1).
/// Rather than passing bare `String`s — where nothing stops a `PersonID` being used
/// where an `ArtifactID` is expected — each record kind gets its own wrapper type.
/// All wrappers encode/decode as a **plain JSON string** (not an object), so the
/// on-disk format is unchanged from a bare string.
///
/// The shared behavior lives in `RecordID`; each concrete type is a one-liner.
public protocol RecordID:
    Codable, Sendable, Hashable, Comparable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    /// The underlying identifier string (e.g. `"ART-018f3c9a-…"`).
    var raw: String { get }
    init(_ raw: String)
}

extension RecordID {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public var description: String { raw }

    // All three literal inits are provided explicitly: ExpressibleByStringLiteral
    // inherits from the grapheme-cluster and unicode-scalar literal protocols, and
    // satisfying them via a protocol extension requires spelling each one out.
    public init(stringLiteral value: String) { self.init(value) }
    public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    public init(unicodeScalarLiteral value: String) { self.init(value) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
}

/// Identifier for an `Artifact` (`ART-…`).
public struct ArtifactID: RecordID {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Identifier for a `FileEntry` (`FIL-…`).
public struct FileID: RecordID {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Identifier for a concluded `Person` (`PER-…`).
public struct PersonID: RecordID {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Identifier for an `EvidenceLink` (`LNK-…`).
public struct EvidenceLinkID: RecordID {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Identifier for a `Relationship` (`REL-…`).
public struct RelationshipID: RecordID {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Identifier for a `Dismissal` (`DSM-…`).
public struct DismissalID: RecordID {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Identifier for an archive as a whole (the archive UUID in `manifest.json`).
public struct ArchiveID: RecordID {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}
