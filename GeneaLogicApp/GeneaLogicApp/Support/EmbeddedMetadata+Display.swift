import GeneaLogicModel

extension EmbeddedMetadataValue {
    /// A plain-text rendering of a captured value — used both to display the
    /// suggestion read-only and as the editable default when a human promotes it
    /// into a genealogical field (the apply step, ARCHITECTURE.md §6.4).
    var displayString: String {
        switch self {
        case .string(let string):
            return string
        case .number(let number):
            // Render whole numbers without a trailing ".0" (EXIF rationals like
            // ISO speed or orientation read as integers).
            if number == number.rounded(), abs(number) < 1e15 {
                return String(Int(number))
            }
            return String(number)
        case .boolean(let bool):
            return bool ? "true" : "false"
        }
    }
}

/// Conservative reshaping of embedded values into the forms genealogical fields
/// expect. Deliberately limited: it only *reformats* punctuation, never invents
/// or corrects content — the value stays a suggestion the human must verify (the
/// scan-date trap, §6.4).
enum SuggestionNormalize {
    /// Best-effort conversion of an EXIF-style `"YYYY:MM:DD HH:MM:SS"` timestamp
    /// to an ISO 8601 date `"YYYY-MM-DD"`. Returns `nil` when the string doesn't
    /// match, leaving the raw value for the user to edit. It never changes the
    /// year — a 2026 scan date stays 2026 so the human sees (and corrects) it.
    static func isoDate(from raw: String) -> String? {
        let datePart = raw.split(separator: " ").first.map(String.init) ?? raw
        let components = datePart.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
            components[0].count == 4,
            components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return "\(components[0])-\(components[1])-\(components[2])"
    }
}
