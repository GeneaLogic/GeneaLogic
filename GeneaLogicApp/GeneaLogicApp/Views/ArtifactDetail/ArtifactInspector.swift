import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The metadata inspector: the descriptive fields, evidence sections (events,
/// places, persons), transcript, files management, embedded-metadata suggestions,
/// and identifiers, in a toggleable trailing inspector beside the document.
///
/// Composition only: each section takes the values it renders and acts on the model
/// itself. What a section needs the coordinator for — a sheet, the file selection —
/// it reaches through a binding.
struct ArtifactInspector: View {
    let artifactID: ArtifactID
    let slug: String
    /// The derived Primary Date (earliest event date), from the browse summary — it
    /// isn't stored on the full `Artifact`.
    let primaryDate: String?
    /// The full record, `nil` until the coordinator has loaded it.
    let detail: Artifact?
    let transcript: String?
    let files: [FileEntry]
    let links: [EvidenceLink]
    let relationshipSuggestions: [RelationshipReviewItem]
    @Binding var selectedFileID: FileID?
    @Binding var sheet: ArtifactSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Details")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Descriptive fields are always editable (no Edit/Done mode) and commit
                // on blur. They need the full record, so they wait for `detail` to load.
                if let detail {
                    EditableArtifactFields(artifact: detail, primaryDate: primaryDate)
                }

                EventsPlacesSection(
                    artifactID: artifactID,
                    events: detail?.events ?? [],
                    locations: detail?.locations ?? [],
                    sheet: $sheet)

                PersonsMentionedSection(
                    artifactID: artifactID,
                    persons: detail?.personsMentioned ?? [],
                    statedRelationships: detail?.mentionRelationships ?? [],
                    links: links,
                    relationshipSuggestions: relationshipSuggestions,
                    sheet: $sheet)

                TranscriptSection(transcript: transcript, sheet: $sheet)

                FilesSection(artifactID: artifactID, files: files, selectedFileID: $selectedFileID)

                EmbeddedMetadataSection(artifactID: artifactID, sheet: $sheet)

                // UID/slug are internal addressing — useful for support, but not
                // the first thing a researcher wants, so they sit de-emphasized
                // at the very bottom.
                IdentifiersSection(uid: artifactID.raw, slug: slug)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // **The inspector sits under the toolbar, like Preview's and Pages'** (slice 80):
        // it describes the artifact in the detail column, so it belongs at that
        // column's level. The inspector always runs full height; what made it look
        // in front of or behind the toolbar was whether SwiftUI drew the toolbar's
        // edge over it, and that depended on how the inspector came to be shown (#9).
        // A hard top edge draws the band and its divider every time.
        .scrollEdgeEffectStyle(.hard, for: .top)
    }
}

/// The artifact's internal identifiers (UID + package slug), shown small and
/// de-emphasized at the bottom of the detail. Not edited; copyable for support.
private struct IdentifiersSection: View {
    let uid: String
    let slug: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                IdentifierRow(label: "UID", value: uid)
                IdentifierRow(label: "Slug", value: slug)
            }
        }
        .padding(.top, 8)
    }

    private struct IdentifierRow: View {
        let label: String
        let value: String

        var body: some View {
            GridRow {
                Text(label)
                    .gridColumnAlignment(.trailing)
                Text(value)
                    .textSelection(.enabled)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }
}
