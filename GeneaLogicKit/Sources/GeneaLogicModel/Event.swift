/// A single event recorded by an artifact (e.g. a census enumeration, a birth).
///
/// Documented in `Artifact.events[]` (ARCHITECTURE.md §4.2).
///
/// NOTE (date representation): `date` is a verbatim `String` because genealogical
/// dates are frequently partial, approximate, uncertain, or ranged. The grammar is
/// **EDTF** (ISO 8601-2 / Library of Congress) — a strict superset of the ISO 8601
/// dates used earlier, so `"1920"` / `"1920-05-12"` remain valid while `"1920~"`
/// (about), `"1900/1905"` (range), and `"../1950"` (before) are now expressible.
/// The string stays authoritative; `EDTFDate.parse` derives sort/range bounds from
/// it (never stored). See `EDTFDate`.
///
/// NOTE (location embedding): The event embeds location as a plain `String`
/// (`"Cook County, Illinois, USA"` in the example). The `Location` struct is
/// a separate concept used in `Artifact.locations[]` with both `asRecorded`
/// and `normalized` fields. The `Event` uses a single string to avoid forcing
/// a normalized form at event-capture time. Flagged for Opus review — the event
/// location could instead reference a `Location` by index or embed the full struct.
public struct Event: Codable, Sendable, Hashable {
    /// Event type string, e.g. `"Census"`, `"Birth"`, `"Death"`.
    /// NOTE: The doc uses bare strings (not an enum) for event types in artifacts,
    /// and GEDCOM X fact types in persons. Kept as `String` for forward-compat.
    public var type: String

    /// ISO 8601 date string (possibly partial). See date note above.
    public var date: String?

    /// Location as recorded in the source document.
    public var location: String?

    public init(
        type: String,
        date: String? = nil,
        location: String? = nil
    ) {
        self.type = type
        self.date = date
        self.location = location
    }
}
