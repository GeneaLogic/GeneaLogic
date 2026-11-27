import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// An artifact's sidebar row: a thumbnail of its scan, or its media type's symbol (84b),
/// then the title over a one-line
/// subtitle of genealogically useful facets (primary date, source tier, media type),
/// *not* the internal UID — which is developer addressing a researcher doesn't browse
/// by, and lives de-emphasized in the detail's Identifiers section (UI audit F1).
struct ArtifactRow: View {
    let summary: ArtifactSummary

    var body: some View {
        HStack(spacing: 8) {
            ArtifactThumbnail(summary: summary)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(1)
                subtitle
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
    }

    /// Primary date (when known) · source tier · media type — the blanks omitted, so a
    /// dateless artifact reads "compiled · image" rather than carrying an empty slot.
    /// The date is glossed to human-readable EDTF ("about 1920"), falling back to the
    /// raw string when it isn't parseable as a date.
    ///
    /// **An unstated tier fills the tier's own slot rather than trailing the line.** It
    /// first shipped (46b) as a separate caption tacked on the end, which made an
    /// uncatalogued row read `image  no source tier` against a catalogued
    /// `government · image` — different order, different separator, different size, for
    /// what is the *same field* in two states. It now reads `no source tier · image`:
    /// identical structure, and only the colour marks it as work owed.
    ///
    /// Built by concatenating `Text` so one run can carry its own colour — deliberately
    /// **not** styled as an error, since uncatalogued is the normal state of a document
    /// that was just dragged in.
    private var subtitle: Text {
        var pieces: [Text] = []
        if let date = summary.primaryDate, !date.trimmingCharacters(in: .whitespaces).isEmpty {
            let gloss = EDTFDate.parse(date)?.humanDescription ?? date
            pieces.append(Text(gloss).foregroundStyle(.secondary))
        }
        if let tier = summary.sourceAuthorityTier {
            pieces.append(Text(tier.rawValue).foregroundStyle(.secondary))
        } else {
            pieces.append(Text("no source tier").foregroundStyle(.orange))
        }
        pieces.append(Text(summary.mediaType.rawValue).foregroundStyle(.secondary))

        let separator = Text(" · ").foregroundStyle(.secondary)
        return pieces.dropFirst().reduce(pieces[0]) { $0 + separator + $1 }
    }
}

/// A sidebar row's leading symbol, in the one tint artifact and Review rows share
/// (slice 84, fork 4), at a fixed width so the titles line up whatever the glyph.
///
/// **Not tinted on a selected row** while the list has focus: the highlight is the same
/// accent, and the symbol vanished into it (84's hand-test). There it takes the row's
/// text colour, as Finder's and Mail's sidebar symbols do.
struct SidebarSymbol: View {
    let name: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(
                prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
            )
            .frame(width: 18)
    }
}

extension MediaType {
    /// The sidebar row's symbol for an artifact of this type.
    var systemImage: String {
        switch self {
        case .image: "photo"
        case .text: "doc.plaintext"
        case .sound: "waveform"
        case .video: "film"
        case .document: "doc.richtext"
        case .unknown: "doc"
        }
    }
}
