import SwiftUI

/// The shared "add" affordance used by every section header (Events & Places,
/// Persons Mentioned, Files, and the People-tab Names/Facts): a leading icon + a
/// title, plus a trailing chevron when the control **opens a menu** (F8). Hosted on
/// a `.buttonStyle(.plain)` button/menu so the label's own `.primary` color is the
/// single source of its appearance — see the note at the Events & Places menu for
/// why `.borderless`/`.borderlessButton` are avoided.
struct AddAffordanceLabel: View {
    let title: String
    let systemImage: String
    var opensMenu: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Label(title, systemImage: systemImage)
            if opensMenu {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
        }
        .foregroundStyle(.primary)
        // The label owns its no-compress rule so every host — menu or button — gets
        // it from this one place; without it the longest label ("Add Person…") could
        // truncate against its section heading in a narrow inspector (F8).
        .fixedSize()
    }
}
