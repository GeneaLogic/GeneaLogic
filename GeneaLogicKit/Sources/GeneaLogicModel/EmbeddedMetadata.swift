import Foundation

/// The embedded-metadata extraction seam (ARCHITECTURE.md §6.4).
///
/// When a file is attached to an artifact, it often carries embedded technical
/// metadata (a photo's EXIF, a document's IPTC/XMP block, …). Extraction of that
/// metadata is a deterministic, testable operation that belongs in the package —
/// but the natural Apple tooling (ImageIO/AVFoundation) is Apple-only, and the
/// core must stay Foundation-only to build on Linux. So the core defines a
/// **neutral value type and protocol**; concrete extractors live in a separate,
/// optional target (`GeneaLogicExtract`, Phase 2) that the core does not depend on.
///
/// **Governing rule (do not violate): embedded metadata is always a *suggestion*,
/// never an auto-applied genealogical fact.** A 2026 scan of an 1920 census has
/// EXIF `DateTimeOriginal` of *today*, not 1920 — auto-applying it to
/// `events[].date` would silently corrupt the archive. `attachFile` therefore
/// only *captures and surfaces* `EmbeddedMetadata`; it never writes any
/// genealogical field (`events`, `locations`, `personsMentioned`, …) from it,
/// and nothing in `GeneaLogicModel` or `GeneaLogicArchive` does either. Turning a
/// captured value into a genealogical assertion is a human-confirmed app-layer
/// decision (Phase 2).
///
/// NOTE (no persisted field — flagged for review): `EmbeddedMetadata` is
/// currently **not** persisted anywhere in `record.json` or `manifest.json`. The
/// Phase 1 `attachFile` surfaces it only as an in-memory return value (see
/// `AttachedFile` in `GeneaLogicArchive`) so the caller (CLI, app) can decide what,
/// if anything, to do with it — including persisting a `machine-suggested`
/// representation later. Adding a persisted field (e.g.
/// `FileEntry.embeddedMetadata` or a sidecar-level `suggestions` bucket) would be
/// a format change and is deliberately deferred to whoever designs the Phase 2
/// ingest-review UI, so the persisted shape can be driven by what that UI actually
/// needs to show/confirm. Flagged for Opus review.

// MARK: - EmbeddedMetadataKey

/// A namespaced metadata key, e.g. `exif:DateTimeOriginal`, `iptc:Caption`,
/// `xmp:CreateDate`. The namespace identifies the embedded-metadata standard the
/// key comes from; the name is that standard's own field name, passed through
/// verbatim (we do not attempt to normalize vocabularies across EXIF/IPTC/XMP).
public struct EmbeddedMetadataKey: Codable, Sendable, Hashable, Comparable,
    CustomStringConvertible
{
    /// The metadata namespace/standard, e.g. `"exif"`, `"iptc"`, `"xmp"`.
    public var namespace: String

    /// The field name within that namespace, passed through verbatim.
    public var name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    /// The canonical `namespace:name` string form, e.g. `"exif:DateTimeOriginal"`.
    public var description: String { "\(namespace):\(name)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.namespace, lhs.name) < (rhs.namespace, rhs.name)
    }

    // Encoded as a single `"namespace:name"` JSON string (not an object) — this
    // mirrors the `RecordID` pattern and keeps any future on-disk representation
    // compact and diff-friendly. The split is on the *first* colon only, so a
    // name containing colons (rare, but XMP allows them) round-trips intact.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let colonIndex = raw.firstIndex(of: ":") {
            self.namespace = String(raw[raw.startIndex..<colonIndex])
            self.name = String(raw[raw.index(after: colonIndex)...])
        } else {
            // No namespace separator — keep the raw string as the name with an
            // empty namespace rather than failing decode (lossless round-trip).
            self.namespace = ""
            self.name = raw
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - EmbeddedMetadataValue

/// The value side of an embedded-metadata entry. Embedded metadata arrives in a
/// handful of shapes (strings, numbers, dates-as-strings, GPS coordinate pairs,
/// …); rather than guess a single Swift type, the seam preserves the extractor's
/// string representation and tags its rough shape so a consumer can decide how to
/// interpret it. This keeps the core dependency-free and avoids baking
/// extractor-specific typing into the model.
public enum EmbeddedMetadataValue: Codable, Sendable, Hashable {
    /// A plain text value, as produced by the extractor.
    case string(String)
    /// A numeric value, preserved as `Double` (covers integer and rational EXIF fields).
    case number(Double)
    /// A boolean flag value.
    case boolean(Bool)

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case string, number, boolean
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .number: self = .number(try container.decode(Double.self, forKey: .value))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - EmbeddedMetadata

/// A neutral, namespaced bag of embedded technical metadata captured from a file
/// at attach time (EXIF/IPTC/XMP/…). Order-independent; entries are looked up by
/// `EmbeddedMetadataKey`.
///
/// This type is intentionally "dumb" — it does not interpret, normalize, or
/// validate any value. Interpretation (deciding what an `exif:GPSLatitude` value
/// *means* for this archive) is app-layer policy (§6.4), not a package concern.
public struct EmbeddedMetadata: Codable, Sendable, Equatable {
    /// The namespaced key→value entries, in extractor-reported order.
    public var entries: [EmbeddedMetadataKeyValue]

    public init(entries: [EmbeddedMetadataKeyValue] = []) {
        self.entries = entries
    }

    /// Convenience accessor: the first value recorded for `key`, if any.
    public subscript(key: EmbeddedMetadataKey) -> EmbeddedMetadataValue? {
        entries.first(where: { $0.key == key })?.value
    }

    /// Whether any metadata was captured at all.
    public var isEmpty: Bool { entries.isEmpty }
}

/// A single namespaced key/value pair within `EmbeddedMetadata`.
///
/// Modeled as a struct (rather than `[EmbeddedMetadataKey: EmbeddedMetadataValue]`)
/// so that (a) JSON encoding doesn't depend on dictionary key ordering — keeping
/// re-encodes diff-stable — and (b) duplicate keys from a sloppy extractor are
/// preserved rather than silently collapsed.
public struct EmbeddedMetadataKeyValue: Codable, Sendable, Equatable {
    public var key: EmbeddedMetadataKey
    public var value: EmbeddedMetadataValue

    public init(key: EmbeddedMetadataKey, value: EmbeddedMetadataValue) {
        self.key = key
        self.value = value
    }
}

// MARK: - MetadataExtractor

/// A pure, deterministic, dependency-free seam for extracting embedded technical
/// metadata from a file on disk.
///
/// Conformers are injected by the caller (CLI, app) into `attachFile`; the core
/// provides **no concrete implementation** (that is `GeneaLogicExtract`, Phase 2 —
/// e.g. an Apple build wrapping ImageIO/AVFoundation, or a cross-platform
/// implementation via libexif/ExifTool/pure-Swift). Keeping the protocol here
/// means the plumbing — where results land, with what provenance — is unit-tested
/// identically for every consumer, without the core ever depending on
/// platform-specific frameworks.
///
/// Conformance requirements: `extract(from:)` MUST be a pure function of the
/// file's bytes (no network, no hidden state) so results are reproducible and
/// testable; it SHOULD return `nil`/empty `EmbeddedMetadata` rather than throwing
/// when a file simply carries no embedded metadata, and reserve `throw` for
/// genuine I/O failure.
public protocol MetadataExtractor: Sendable {
    /// Extracts whatever embedded metadata can be read from the file at `url`.
    ///
    /// - Parameter url: A file URL to a local, already-readable file (the archive
    ///   has already copied it in by the time this is called).
    /// - Returns: The captured metadata, or empty `EmbeddedMetadata` if the file
    ///   carries none.
    /// - Throws: On genuine I/O or parse failure. A file with no embedded
    ///   metadata is not an error.
    func extract(from url: URL) throws -> EmbeddedMetadata
}
