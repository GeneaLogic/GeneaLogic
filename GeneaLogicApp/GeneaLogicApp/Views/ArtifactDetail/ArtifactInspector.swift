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
        // **Content stops at the toolbar's lower edge, as in Preview and Pages** (slice
        // 80). SwiftUI lays the inspector column out full height, behind the toolbar,
        // and lets the scroll view draw up into it. Whether the toolbar's edge effect
        // then covers that content depends on how the inspector came to be shown (#9):
        // sharp text under the toolbar at first, blurred after a hide and show. So the
        // content never goes there. The scroll view's frame stops at the toolbar's
        // lower edge even though it draws past it, so clipping to the frame cuts the
        // overflow (the sides and bottom never draw past it), and the content shape
        // keeps controls hidden under the toolbar from taking clicks.
        //
        // **The three lines are one workaround, removed together** when the repro in
        // `scripts/inspector-edge-repro/` shows Apple has fixed #9. With the clip gone,
        // the hidden edge effect would leave content under the toolbar with no backing
        // at all.
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .clipped()
            .contentShape(Rectangle())
    }

    private var content: some View {
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
