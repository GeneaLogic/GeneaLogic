import SwiftUI

/// The value that drives a popped-out preview window. `url` is a session-temp
/// **copy** of the attached file (made via `ArchiveModel.temporaryCopy`), not the
/// package original — so the window needs no archive access of its own and can't
/// mutate package contents. `title` is the file's `originalName`.
///
/// `Codable`/`Hashable` so it can ride `WindowGroup(for:)`; the group disables
/// restoration (a temp-copy URL wouldn't survive relaunch and a preview window
/// isn't worth restoring).
struct FilePreviewRequest: Codable, Hashable {
    let url: URL
    let title: String
}

/// Content of a popped-out preview window: a full-window Quick Look of the temp
/// copy.
struct FilePreviewWindow: View {
    let request: FilePreviewRequest?

    var body: some View {
        Group {
            if let request {
                FilePreviewContent(url: request.url)
                    .navigationTitle(request.title)
            } else {
                ContentUnavailableView(
                    "No File", systemImage: "doc",
                    description: Text("This preview window has no file to show."))
            }
        }
        .frame(minWidth: Layout.PreviewWindow.minWidth, minHeight: Layout.PreviewWindow.minHeight)
    }
}
