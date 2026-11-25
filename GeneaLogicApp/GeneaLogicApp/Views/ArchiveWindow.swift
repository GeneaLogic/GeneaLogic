import SwiftUI

/// The content of one window in the value-based `WindowGroup(for: URL.self)`: the archive
/// at the window's URL. The welcome screen is a scene of its own (slice 85b), so every
/// window here has an archive.
struct ArchiveWindow: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let url {
            // `.id(url)` ties the container's identity (and its per-window
            // `ArchiveModel`) to the URL, so the model is never reused for a
            // different archive.
            ArchiveContainerView(url: url)
                .id(url)
        } else {
            // A restored window has no value yet when it first appears; SwiftUI sets it a
            // moment later (about 60 ms, measured). One that stays empty is a welcome
            // window saved before 85b, so it closes.
            Color.clear
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    dismiss()
                    DispatchQueue.main.async {
                        ArchiveOpenCoordinator.shared.emptyWindowDidClose()
                    }
                }
        }
    }
}
