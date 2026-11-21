import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// An artifact's sidebar row: its media type's symbol, then the title over a one-line
/// subtitle of genealogically useful facets (primary date, source tier, media type),
/// *not* the internal UID — which is developer addressing a researcher doesn't browse
/// by, and lives de-emphasized in the detail's Identifiers section (UI audit F1).
struct ArtifactRow: View {
    let summary: ArtifactSummary

    var body: some View {
        HStack(spacing: 8) {
            SidebarSymbol(name: summary.mediaType.systemImage)
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
                prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
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

/// Delete Artifact…'s confirm, from ⌫, the File and Artifact menus and a row's context
/// menu. On the sidebar as a whole rather than on the artifact rows, so it still works
/// with the section collapsed or a search showing none of them.
struct ArtifactDeleteConfirmation: ViewModifier {
    @Environment(ArchiveModel.self) private var model

    /// The artifact awaiting confirmation.
    @State private var pendingDelete: ArtifactSummary?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingCommand) {
                guard let (_, subject) = model.claimPendingCommand({ $0 == .deleteArtifact }),
                    case .artifact(let id) = subject,
                    // Against the full list, so a search narrowing the sidebar doesn't lose
                    // the target.
                    let summary = model.artifacts.first(where: { $0.uid == id })
                else { return }
                pendingDelete = summary
            }
            .confirmationDialog(
                pendingDelete.map { "Delete “\($0.title)”?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { artifact in
                Button("Delete Artifact", role: .destructive) {
                    model.deleteArtifact(artifact.uid)
                }
            } message: { artifact in
                Text(Self.message(for: artifact))
            }
            .reportsModal(pendingDelete != nil)
    }

    private static func message(for artifact: ArtifactSummary) -> String {
        let files =
            artifact.fileCount == 1
            ? "its 1 attached file" : "its \(artifact.fileCount) attached files"
        let scope = artifact.fileCount == 0 ? "this artifact" : "this artifact and \(files)"
        return "This removes \(scope) from the archive. You can undo it with ⌘Z."
    }
}
