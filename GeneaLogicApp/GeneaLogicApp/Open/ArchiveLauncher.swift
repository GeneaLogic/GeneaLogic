import AppKit
import Foundation
import GeneaLogicArchive
import UniformTypeIdentifiers

/// Thin AppKit helpers for choosing a `.genea` archive package location.
///
/// These back the **File-menu** commands, which must work with no window
/// present — a `Commands` body can't host a SwiftUI `.fileImporter`, so it uses
/// `NSOpenPanel`/`NSSavePanel`, which present window-independently. (The welcome
/// screen, being a view, opens with its own `.fileImporter` instead — that path
/// stays declarative and computer-use-drivable.) Create has no `.fileImporter`
/// equivalent in either place: there's no SwiftUI idiom for "pick a
/// not-yet-existing destination the engine will populate", so it's always an
/// `NSSavePanel`.
enum ArchiveLauncher {
    /// Where to create a new archive, and whether its extension is hidden there.
    struct NewArchiveLocation {
        let url: URL
        let hidesExtension: Bool
    }

    /// Shows an `NSSavePanel` for choosing where to create a new `.genea`
    /// archive package, returning the chosen location (not yet created on disk —
    /// `create(at:)` creates the package), or `nil` if the user cancelled.
    ///
    /// The panel works with the type, not a typed name, so it handles the extension
    /// itself and reports whether to hide it, as for any `NSDocument` app (slice 81,
    /// G21). That starts out hidden and becomes shown only if the user types `.genea`
    /// into the name. There is no Hide Extension checkbox, as in Pages and TextEdit.
    static func newArchiveLocation() -> NewArchiveLocation? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.geneaArchive]
        panel.nameFieldStringValue = "Untitled"
        panel.canCreateDirectories = true
        panel.message = "Choose a name and location for the new GeneaLogic archive."
        panel.prompt = "Create"

        guard panel.runModal() == .OK, var url = panel.url else { return nil }

        if url.pathExtension != "genea" {
            url.appendPathExtension("genea")
        }

        return NewArchiveLocation(url: url, hidesExtension: panel.isExtensionHidden)
    }

    /// Creates the archive at a location the save panel chose, with its extension
    /// hidden or shown as the panel said. File ▸ New Archive… and the welcome screen
    /// both create through here; each then acquires access and opens the window its
    /// own way.
    static func create(at location: NewArchiveLocation) throws {
        _ = try Archive.create(at: location.url)
        try setExtensionHidden(location.hidesExtension, at: location.url)
    }

    /// Sets the file system's hidden-extension flag, which the window title's path
    /// menu and Finder both follow. Only on an archive the app has just created: on
    /// an existing one the flag is the user's, and Finder's Get Info changes it.
    nonisolated static func setExtensionHidden(_ hidden: Bool, at url: URL) throws {
        var values = URLResourceValues()
        values.hasHiddenExtension = hidden
        var url = url
        try url.setResourceValues(values)
    }

    /// Shows an `NSOpenPanel` for choosing an existing `.genea` archive package,
    /// returning the chosen `URL` or `nil` if the user cancelled. The package is
    /// selected as a single unit (not traversed into), filtered to the registered
    /// `.genea` type.
    static func openPanelURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.geneaArchive]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a GeneaLogic archive to open."
        panel.prompt = "Open"

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
