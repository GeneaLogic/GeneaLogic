import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The Person menu's three adds, on the tree (slice 84's hand-test).
///
/// The tree runs People's menu-bar verbs (`ArchiveTab.runs`), but these three open
/// sheets the person's page owns, and the page isn't showing on the tree: Add Name…,
/// Add Fact… and Add Relationship… were enabled and did nothing. This hosts the same
/// sheets over the tree, on the person the menu names, and the tree redraws from the
/// write (`mutationVersion`). Not a switch to the list first: leaving the tree to add a
/// fact would lose your place, which the creates were changed for.
struct TreePersonAdds: ViewModifier {
    @Environment(ArchiveModel.self) private var model

    /// The add the menu asked for, and on whom.
    @State private var request: Request?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingCommand) {
                guard
                    let (command, subject) = model.claimPendingCommand({
                        $0 == .addName || $0 == .addFact || $0 == .addRelationship
                    }),
                    case .person(let person) = subject,
                    request == nil
                else { return }
                request = Request(command: command, person: person)
            }
            .sheet(item: $request) { request in
                Group {
                    switch request.command {
                    case .addName:
                        PersonEditorSheet(personID: request.person, index: nil, existing: nil)
                    case .addFact:
                        FactEditorSheet(personID: request.person, mode: .add)
                    default:
                        RelationshipEditorSheet(
                            subjectID: request.person, subjectName: name(of: request.person))
                    }
                }
                .environment(model)
            }
            .reportsModal(request != nil)
    }

    private struct Request: Identifiable {
        let id = UUID()
        let command: ArchiveCommand
        let person: PersonID
    }

    private func name(of id: PersonID) -> String {
        model.persons.first { $0.uid == id }?.displayName ?? "Unnamed person"
    }
}
