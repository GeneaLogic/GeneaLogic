import SwiftUI

/// The content of one window in the value-based `WindowGroup(for: URL.self)`: the archive
/// at the window's URL. The welcome screen is a scene of its own (slice 85b), so every
/// window here has an archive.
struct ArchiveWindow: View {
    let url: URL?
    @State private var isSettled = false

    var body: some View {
        if let url {
            // `.id(url)` ties the container's identity (and its per-window
            // `ArchiveModel`) to the URL, so the model is never reused for a
            // different archive.
            ArchiveContainerView(url: url)
                .id(url)
        } else {
            // A restored window has no value yet when it first appears; SwiftUI sets it a
            // moment later (about 60 ms, measured). So this never closes the window: closing
            // it at once lost the archive, and any deadline could. One that stays empty says
            // so, after long enough not to flash.
            ContentUnavailableView(
                "No Archive", systemImage: "archivebox",
                description: Text("Open an archive from the File menu.")
            )
            .opacity(isSettled ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { isSettled = true }
            }
        }
    }
}
