import AppKit
import GeneaLogicArchive
import SwiftUI
import UniformTypeIdentifiers

/// The welcome window (slice 85b): the ways into an archive. It may sit beside open
/// archives, and closes when one is opened, here or anywhere else
/// (`ArchiveOpenCoordinator`).
struct WelcomeView: View {
    static let windowID = "welcome"

    /// Drives the open `.fileImporter`, the only importer in this window (an archive's
    /// is in its own), so the "one live importer per hierarchy" constraint holds.
    @State private var isOpening = false
    /// Local create/open failure message, shown as an alert.
    @State private var errorMessage: String?
    /// True while the sample is being built, so a second click can't start another.
    @State private var isPreparingSample = false

    /// The persisted recents (F4), read here so the list updates live as archives
    /// are opened or removed (`ArchiveBookmarks` is `@Observable`).
    @State private var bookmarks = ArchiveBookmarks.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("GeneaLogic")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Open an existing archive or create a new one to get started.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Neither button is the default action: in the empty state there's no
            // obviously-primary choice, so Return does nothing rather than
            // misleadingly activating one.
            HStack(spacing: 12) {
                Button("Open Archive…") { isOpening = true }
                Button("New Archive…") { createArchive() }
            }
            .padding(.top, 8)

            // Quieter than Open and New: a way in for someone with no archive yet,
            // offered always.
            Button("Explore a Sample Archive") { openSample() }
                .buttonStyle(.link)
                .disabled(isPreparingSample)

            if !bookmarks.recents.isEmpty {
                recentsSection
            }
        }
        .padding(40)
        .frame(width: Layout.WelcomeWindow.width)
        // The window is the content's size (`.windowResizability(.contentSize)`).
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(
            isPresented: $isOpening,
            allowedContentTypes: [.geneaArchive],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                // Acquire on the **original** scoped URL (canonicalizing rebuilds it
                // from a path and would drop the security scope); canonicalize only
                // the value of the archive's window — it's persisted for state
                // restoration, and a later Finder-open must dedup against it (slice 31).
                guard let picked = urls.first else { return }
                ArchiveAccessStore.shared.acquire(picked)
                open(picked.canonicalArchiveURL)
            case .failure(let error):
                errorMessage = String(describing: error)
            }
        }
        .alert("Error", isPresented: hasError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Opens the archive in its own window, or focuses that window, and closes this one.
    private func open(_ url: URL) {
        ArchiveOpenCoordinator.shared.open(url)
    }

    /// Creates a new `.genea` package at a user-chosen location, then opens it.
    private func createArchive() {
        guard let location = ArchiveLauncher.newArchiveLocation() else { return }
        do {
            open(try ArchiveLauncher.create(at: location))
        } catch {
            errorMessage = (error as? ArchiveError)?.description ?? String(describing: error)
        }
    }

    /// Opens the sample, building it first if it isn't there yet
    /// (slice 74b). Its home is the app's container; see `SampleArchiveLauncher`.
    private func openSample() {
        isPreparingSample = true
        Task {
            defer { isPreparingSample = false }
            do {
                let location = try SampleArchiveLauncher.defaultLocation()
                let sample = try await Task.detached {
                    try SampleArchiveLauncher.prepare(at: location)
                }.value
                ArchiveAccessStore.shared.acquire(sample)
                open(sample.canonicalArchiveURL)
            } catch {
                errorMessage = (error as? ArchiveError)?.description ?? String(describing: error)
            }
        }
    }

    // MARK: - Recent archives (F4)

    /// A compact list of recently opened archives, below the Open/New buttons.
    /// Height-capped and scrollable so a full recents list (up to 10) can't push
    /// the welcome content off-screen; hidden entirely when there are no recents.
    private var recentsSection: some View {
        let urls = bookmarks.recentURLs()
        // Hug the content for a few recents; scroll once it would grow too tall.
        let rowHeight: CGFloat = 44
        let listHeight = min(CGFloat(urls.count) * rowHeight, rowHeight * 5)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(urls, id: \.self) { recent in
                        RecentArchiveRow(url: recent) { openRecent(recent) }
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([recent])
                                }
                                Button("Remove from Recents") {
                                    bookmarks.removeRecent(recent)
                                }
                            }
                    }
                }
            }
            .frame(height: listHeight)
        }
        .frame(width: 360)
        .padding(.top, 8)
    }

    /// Reopens a recent archive (`reopenRecent` is the policy, shared with File ▸ Open
    /// Recent). If it moved or was deleted, its window shows the "can no longer reach this
    /// archive" state.
    private func openRecent(_ recent: URL) {
        open(ArchiveAccessStore.shared.reopenRecent(recent))
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

/// One tappable recent-archive row: archive name over its dimmed, tilde-abbreviated
/// containing folder, with a hover highlight (mirrors the detail-pane file rows).
private struct RecentArchiveRow: View {
    let url: URL
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(displayFolder)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .hoverRowBackground(isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// The containing folder, tilde-abbreviated (`/Users/x/Public` → `~/Public`),
    /// so two same-named archives in different folders are distinguishable.
    private var displayFolder: String {
        let folder = url.deletingLastPathComponent().path
        // `NSString.abbreviatingWithTildeInPath` keys off `NSHomeDirectory()`, which
        // in a sandboxed app is the *container* path — so it never matches a real
        // `/Users/<name>` path. Resolve the actual home via the passwd database.
        let home = Self.realHomeDirectory
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    /// The user's real home directory (`/Users/<name>`), not the sandbox container
    /// that `NSHomeDirectory()` reports. Read once from the passwd database.
    private static let realHomeDirectory: String = {
        guard let pw = getpwuid(getuid()) else { return NSHomeDirectory() }
        return String(cString: pw.pointee.pw_dir)
    }()
}
