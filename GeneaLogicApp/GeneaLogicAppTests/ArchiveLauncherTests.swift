import AppKit
import Foundation
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 81 — an archive the app creates has its extension hidden unless the save panel
/// said to show it (G21), and the About panel's credits read in dark mode (G17).
@Suite struct ArchiveLauncherTests {

    private func location(hidesExtension: Bool) -> ArchiveLauncher.NewArchiveLocation {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveLauncherTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Family.genea", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return ArchiveLauncher.NewArchiveLocation(url: url, hidesExtension: hidesExtension)
    }

    private func hasHiddenExtension(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension ?? false
    }

    @Test func aNewArchiveHidesItsExtension() throws {
        let location = location(hidesExtension: true)
        try ArchiveLauncher.create(at: location)

        #expect(try hasHiddenExtension(location.url))
        #expect(FileManager.default.displayName(atPath: location.url.path) == "Family")
        _ = try Archive.open(at: location.url)
    }

    /// The user typed `.genea` into the panel's name, so the panel said to show it.
    @Test func aNewArchiveShowsItsExtensionWhenAsked() throws {
        let location = location(hidesExtension: false)
        try ArchiveLauncher.create(at: location)

        #expect(try !hasHiddenExtension(location.url))
    }

    /// The standard About panel shows `Credits.rtf` as written. A text colour in it
    /// would be fixed, and black is unreadable in dark mode; with none, the panel's
    /// own colour is used.
    @Test func theCreditsSetNoTextColour() throws {
        let url = try #require(Bundle.main.url(forResource: "Credits", withExtension: "rtf"))
        let credits = try NSAttributedString(url: url, options: [:], documentAttributes: nil)

        #expect(credits.length > 0)
        var colours = 0
        credits.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: credits.length)
        ) { value, _, _ in
            if value != nil { colours += 1 }
        }
        #expect(colours == 0)
    }
}
