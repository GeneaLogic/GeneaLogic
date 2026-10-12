import Foundation

/// Canonical JSON encoding/decoding configuration for the GeneaLogic archive format.
///
/// # Design decisions
///
/// ## Key ordering: `.sortedKeys`
/// All encoders use `.sortedKeys` so that JSON serialization is deterministic
/// across Swift runtime versions and platforms. This is essential for:
/// - Stable diffs when a record is re-encoded after a metadata edit.
/// - Reproducible SHA-256 checksums if canonical JSON is ever used as a checksum input.
/// - Golden fixture tests: re-encoding a decoded fixture must produce the same bytes.
///
/// ## Pretty printing: `.prettyPrinted` for fixtures and human-readable output
/// The `encoder` (used for archive writes and canonical form) uses `.sortedKeys` only.
/// The `prettyEncoder` adds `.prettyPrinted` for fixture files and debugging.
/// Both produce equivalent decoded values.
///
/// ## Date strategy: none (verbatim EDTF strings throughout)
/// Dates are stored as verbatim **EDTF** (ISO 8601-2 / Library of Congress) strings in all
/// model types — a strict superset of plain ISO 8601 that also expresses approximate,
/// uncertain, and ranged dates (see `EDTFDate`). `JSONEncoder.dateEncodingStrategy` is
/// irrelevant here. See individual type notes for the rationale.
///
/// ## Data strategy: `.base64`
/// The default `.base64` strategy is used for any `Data` fields (none in Phase 0,
/// but stated explicitly for future-proofing).
///
/// ## Non-conforming float strategy: `.throw`
/// NaN and infinity are rejected at encode time. No genealogical float should be
/// non-finite; this surfaces bugs early.
public enum GeneaLogicJSON {
    /// The canonical encoder for archive writes. Keys are sorted for stable diffs.
    /// Use this whenever writing a record to disk.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .throw
        return e
    }()

    /// Pretty-printing encoder for fixture files, debug output, and human-readable display.
    /// Produces the same decoded value as `encoder` but with indentation and sorted keys.
    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.nonConformingFloatEncodingStrategy = .throw
        return e
    }()

    /// The canonical decoder. No special strategies needed since all dates/data are strings.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
