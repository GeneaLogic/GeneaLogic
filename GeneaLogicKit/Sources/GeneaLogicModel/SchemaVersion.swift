/// The archive schema version this build of the model writes.
///
/// `schemaVersion` is **not** a parameter of the public initializers — the engine
/// owns the format version, so newly-constructed records always carry `current`.
/// Decoding preserves whatever version is on disk (for migration), independent of
/// this value.
///
/// **The version is archive-wide** (spec §8, slice 64): every record's stamp MUST
/// equal the manifest's, and a build does not edit an archive whose version it
/// does not know. The comparison below is what every such decision uses.
public enum SchemaVersion {
    /// The current archive format version (see `schema/genealogic-archive-1.0.md`).
    public static let current = "1.0"

    /// `major.minor`, both non-negative integers — or `nil` for anything else.
    public static func parse(_ version: String) -> (major: Int, minor: Int)? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let major = Int(parts[0]), let minor = Int(parts[1]),
            major >= 0, minor >= 0,
            // `Int("+1")` and `Int("01")` both parse; neither is a version a
            // build ever wrote, and treating them as one would let a hand edit
            // pass as current.
            String(major) == parts[0], String(minor) == parts[1]
        else { return nil }
        return (major, minor)
    }

    /// Whether `version` is newer than `reference` — the question every refusal
    /// asks. **An unparsable `version` is newer**: a stamp this build cannot read
    /// is not one it can vouch for, so it fails closed (spec §8). Two unparsable
    /// strings compare as `false` unless they differ, so a nonsense manifest
    /// version does not make every record look newer than it.
    public static func isNewer(_ version: String, than reference: String) -> Bool {
        switch (parse(version), parse(reference)) {
        case (let v?, let r?):
            return (v.major, v.minor) > (r.major, r.minor)
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            return version != reference
        }
    }

    /// The newer of the two, under `isNewer` — `a` when they are equal.
    public static func newer(_ a: String, _ b: String) -> String {
        isNewer(b, than: a) ? b : a
    }
}
