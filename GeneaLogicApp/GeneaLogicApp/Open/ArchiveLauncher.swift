import AppKit
import Foundation
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
    /// Shows an `NSSavePanel` for choosing where to create a new `.genea`
    /// archive package, returning the chosen `URL` (not yet created on disk —
    /// `Archive.create` creates the package directory), or `nil` if the user
    /// cancelled.
    static func savePanelURL() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.genea"
        panel.canCreateDirectories = true
        panel.message = "Choose a name and location for the new GeneaLogic archive."
        panel.prompt = "Create"

        guard panel.runModal() == .OK, var url = panel.url else { return nil }

        if url.pathExtension != "genea" {
            url.appendPathExtension("genea")
        }

        return url
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
