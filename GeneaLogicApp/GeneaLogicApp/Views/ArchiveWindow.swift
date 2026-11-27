import SwiftUI

/// The content of one window in the value-based `WindowGroup(for: URL.self)`: the archive
/// at the window's URL. The welcome screen is a scene of its own (slice 85b), so every
/// window here has an archive.
struct ArchiveWindow: View {
    /// The window's value: its de-duplication key, its claim, its title and what the next
    /// launch restores. Written once, if the archive moved since it was saved.
    @Binding var url: URL?
    /// The URL whose move has been followed, so the archive can be built there.
    @State private var followed: URL?
    @State private var isSettled = false

    var body: some View {
        Group {
            if let url, url == followed {
                // `.id(url)` ties the container's identity (and its per-window
                // `ArchiveModel`) to the URL, so the model is never reused for a
                // different archive.
                ArchiveContainerView(url: url)
                    .id(url)
            } else {
                // A restored window has no value yet when it first appears; SwiftUI sets it
                // a moment later (about 60 ms, measured). So this never closes the window:
                // closing it at once lost the archive, and any deadline could. One that stays
                // empty says so, after long enough not to flash.
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
        // Before the archive is built (slice 85c): a window restored for an archive that was
        // moved or renamed while the app was quit takes the new URL, so its model, claim,
        // title and state (85) are the new path's from the first frame, and the next launch
        // restores it there. An open in this session already holds access, so `restore`
        // leaves it as it is.
        .onChange(of: url, initial: true) { _, url in
            guard let url else { return }
            let location = ArchiveAccessStore.shared.restore(url)
            if location != url.canonicalArchiveURL {
                self.url = location
            } else {
                followed = url
            }
        }
    }
}
