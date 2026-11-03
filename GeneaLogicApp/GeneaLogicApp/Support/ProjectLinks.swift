import Foundation

/// The project's pages on the web, for the Help menu (slice 81). `Credits.rtf`, which
/// the About panel shows, links the same home page and licence.
enum ProjectLinks {
    static let home = URL(string: "https://github.com/GeneaLogic/GeneaLogic")!
    /// GitHub's template chooser: the bug report and feature request forms.
    static let newIssue = URL(string: "https://github.com/GeneaLogic/GeneaLogic/issues/new/choose")!
}
