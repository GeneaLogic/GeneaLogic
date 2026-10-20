import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Read-only "Embedded metadata (suggestions)" section, shown when EXIF/IPTC/GPS
/// data has been captured for this artifact's file this session — either at ingest
/// or on demand via a file row's **Scan for Metadata** (the cache is session-only).
/// Absent otherwise.
///
/// Nothing here is written to `events`, `locations`, or any other genealogical
/// field automatically (ARCHITECTURE.md §6.4 — the "scan-date trap"). Each row
/// offers an explicit **Apply…** action that opens a human-confirmed sheet where
/// the user picks the target field and corrects the value before it's written.
///
/// Reads the model's session cache itself: nothing else on the detail renders it, so
/// a scan redraws this section alone.
struct EmbeddedMetadataSection: View {
    @Environment(ArchiveModel.self) private var model
    let artifactID: ArtifactID
    @Binding var sheet: ArtifactSheet?

    var body: some View {
        if let metadata = model.capturedMetadata[artifactID], !metadata.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Embedded Metadata (Suggestions)")
                    .font(.headline)

                Text(
                    "Read from the file's embedded metadata. Not applied to any date, place, or other field — review, then Apply only what you've verified."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Grid(
                    alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4
                ) {
                    ForEach(metadata.entries, id: \.key) { entry in
                        EmbeddedMetadataRow(entry: entry, sheet: $sheet)
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

/// A single `namespace:name` → value row, with an Apply action to promote it.
private struct EmbeddedMetadataRow: View {
    let entry: EmbeddedMetadataKeyValue
    @Binding var sheet: ArtifactSheet?

    var body: some View {
        GridRow {
            Text(entry.key.description)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(entry.value.displayString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button("Apply…") { sheet = ArtifactSheet(.assertion(.suggestion(entry))) }
                .font(.caption)
                .buttonStyle(.link)
        }
    }
}
