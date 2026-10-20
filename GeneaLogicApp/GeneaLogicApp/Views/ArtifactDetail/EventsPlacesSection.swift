import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The artifact's recorded events and places, with an **Add…** menu that opens the
/// blank assertion editor (manual event/place entry — the path for files that carry
/// no usable embedded metadata) and a per-row remove. Promoting an embedded
/// suggestion lands here too; both write `events`/`locations` via `updateMetadata`,
/// so a removal is undoable like any other edit.
///
/// Rich editing of an existing event is deferred to the Phase 3 conclusions UI;
/// here the verbs are add and remove.
struct EventsPlacesSection: View {
    @Environment(ArchiveModel.self) private var model
    let artifactID: ArtifactID
    let events: [Event]
    let locations: [Location]
    @Binding var sheet: ArtifactSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Events & Places")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Add Event…", systemImage: "calendar") {
                        sheet = ArtifactSheet(.assertion(.blankEvent))
                    }
                    Button("Add Place…", systemImage: "mappin.and.ellipse") {
                        sheet = ArtifactSheet(.assertion(.blankPlace))
                    }
                } label: {
                    AddAffordanceLabel(title: "Add…", systemImage: "plus", opensMenu: true)
                }
                // `.menuStyle(.button)` + `.buttonStyle(.plain)` renders the *full*
                // custom label faithfully (so `AddAffordanceLabel`'s own chevron shows,
                // matching the Files button) and imposes no foreground of its own — the
                // label's `.primary` color wins. `.borderless`/`.borderlessButton` each
                // mute the label (which read as disabled) and `.borderlessButton` also
                // drops the custom chevron, which is what made the affordances mismatch (F8).
                // `.plain` already suppresses the native menu indicator; hiding it is
                // explicit belt-and-suspenders so our own chevron is the only one.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }

            if events.isEmpty && locations.isEmpty {
                Text("No events or places recorded. Use Add… to record one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events.keyedRows()) { row in
                        let event = row.element
                        AssertionRow(
                            title: event.type.isEmpty ? "Event" : event.type,
                            subtitle: eventSubtitle(event),
                            icon: "calendar"
                        ) { deleteEvent(event, near: row.index) }
                    }
                    ForEach(locations.keyedRows()) { row in
                        let location = row.element
                        AssertionRow(
                            title: location.asRecorded,
                            subtitle: location.normalized,
                            icon: "mappin.and.ellipse"
                        ) { deletePlace(location, near: row.index) }
                    }
                }
                // Rows are keyed by value, and two artifacts can record an equal event:
                // a row's state belongs to this artifact's list (79b).
                .id(artifactID)
            }
        }
        .padding(.top, 8)
    }

    /// Removes `event` (undoable, like every `updateMetadata` write). `index` is where
    /// the row was drawn, a hint checked against the value in the record the write
    /// reads, so a list that shifted since removes this event or nothing (79b).
    private func deleteEvent(_ event: Event, near index: Int) {
        model.updateMetadata(of: artifactID, actionName: "Remove Event") {
            guard let position = $0.events.position(of: event, near: index) else { return }
            $0.events.remove(at: position)
        }
    }

    /// Removes `location` (undoable). See `deleteEvent` on addressing.
    private func deletePlace(_ location: Location, near index: Int) {
        model.updateMetadata(of: artifactID, actionName: "Remove Place") {
            guard let position = $0.locations.position(of: location, near: index) else {
                return
            }
            $0.locations.remove(at: position)
        }
    }

    /// "about 1920 · Cook County, Illinois", either part omitted when absent. The date
    /// is glossed to human-readable EDTF, falling back to the raw string when it isn't
    /// parseable as a date (free text is kept verbatim).
    private func eventSubtitle(_ event: Event) -> String? {
        let dateText = event.date?.trimmedNonEmpty.map {
            EDTFDate.parse($0)?.humanDescription ?? $0
        }
        let parts = [dateText, event.location?.trimmedNonEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
