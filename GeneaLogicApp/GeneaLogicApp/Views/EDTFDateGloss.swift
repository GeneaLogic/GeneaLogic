import GeneaLogicModel
import SwiftUI

/// A live, non-blocking read-back of an EDTF date field: the human-readable gloss
/// when the value parses (after shorthand normalization — "abt 1892" → "about 1892"),
/// else a gentle note that it will be kept as free text. Genealogical dates must allow
/// the unparseable, so this never gates the surrounding form — it only reflects what
/// will be stored. Shared by the assertion editor (event dates) and the person editor
/// (fact dates); both feed it the field's current text (UI audit F12).
struct EDTFDateGloss: View {
    let dateText: String

    var body: some View {
        let trimmed = dateText.trimmed
        if !trimmed.isEmpty {
            let normalized = EDTFDate.normalizingShorthand(trimmed)
            if let edtf = EDTFDate.parse(normalized) {
                Label("→ \(edtf.humanDescription)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Label(
                    "Not a standard date — it'll be stored as text.",
                    systemImage: "text.quote"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
    }
}
