import CoreTransferable
import GeneaLogicArchive
import GeneaLogicModel

/// What a copied artifact or person reads as, pasted as text (slice 87, fork 1): the row's
/// name, then the primary date the row shows beside it, so two of one name stay apart.
/// `Letter from Karl (about 1903)`, `Anna Lindqvist (about 1872)`.
enum CopyText {
    static func line(name: String, primaryDate: String?) -> String {
        guard let date = primaryDate?.trimmed, !date.isEmpty else { return name }
        return "\(name) (\(EDTFDate.parse(date)?.humanDescription ?? date))"
    }
}

extension ArtifactSummary {
    var copyText: String {
        CopyText.line(name: ArtifactTitle.display(title), primaryDate: primaryDate)
    }
}

extension PersonSummary {
    /// "Unnamed person", as the People list shows one with no name.
    var copyText: String {
        CopyText.line(name: displayName ?? "Unnamed person", primaryDate: primaryDate)
    }
}

/// A copied artifact or person, as ⌘C hands it to the pasteboard (`.copyable`). Text is its
/// only representation for now. A record's own, for pasting into another archive (#93),
/// would go first, so a text field still gets the line.
struct CopiedRecord: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text)
    }
}
