import GeneaLogicArchive
import GeneaLogicModel

extension PersonSummary {
    /// The one-line browse subtitle shared by the People list and the resolve-mention
    /// picker: the primary date (EDTF-glossed to "about 1920" when parseable) · fact
    /// count. One source of truth so the same person reads identically on both surfaces
    /// (they previously drifted — the picker omitted a zero fact count the list showed).
    var browseSubtitle: String {
        var parts: [String] = []
        if let date = primaryDate, !date.trimmed.isEmpty {
            parts.append(EDTFDate.parse(date)?.humanDescription ?? date)
        }
        parts.append(factCount == 1 ? "1 fact" : "\(factCount) facts")
        return parts.joined(separator: " · ")
    }
}
