import GeneaLogicArchive
import GeneaLogicMatch
import GeneaLogicModel
import SwiftUI

/// What Review's commands need beyond any one pane, on the detail column (slice 83).
///
/// **Here rather than on the panes,** because a command can name a row that isn't showing:
/// a row's context menu doesn't select it, so a pane that owned This Is Somebody New…'s
/// sheet would be another row's, and the request would be dropped. The detail column is
/// there whichever pane is, and whether or not the sidebar is hidden.
///
/// It also keeps the Review menu's mirror of the selection, and moves the selection on
/// when the selected row leaves the worklist.
struct ReviewCommandHost: ViewModifier {
    @Environment(ArchiveModel.self) private var model
    @Binding var selection: ReviewItem.ID?

    /// The somebody-new confirm step, carrying the below-threshold candidates it will show.
    ///
    /// Loaded here, before presenting, rather than by the sheet on appear: a `.fitted` sheet
    /// measures its content once at open, so one that fills in afterwards is sized for
    /// content it doesn't have yet.
    @State private var creationRequest: CreationRequest?
    /// ⌘↩ on a suggestion that can only be applied.
    @State private var factRequest: ReviewFactRequest?
    /// Review ▸ Merge People…, asking which record to keep.
    @State private var mergeChoice: DuplicateReviewItem?

    func body(content: Content) -> some View {
        content
            .onChange(of: selection, initial: true) { _, id in model.selectedReviewID = id }
            .onDisappear { model.selectedReviewID = nil }
            // On any way out, not only ⌘↩: the same verb from a pane's button, a sheet or
            // a merge moves on the same, and a row that stays keeps the selection.
            .onChange(of: model.reviewRows) { before, after in
                guard let selection, !after.contains(where: { $0.id == selection }) else {
                    return
                }
                self.selection = ReviewTarget.rowAfter(selection, before: before, after: after)
            }
            .onChange(of: model.pendingCommand) {
                guard
                    let (command, subject) = model.claimPendingCommand({
                        $0 == .somebodyNew || $0 == .mergeDuplicate || $0 == .acceptSuggestion
                    }),
                    case .review(let target) = subject
                else { return }
                perform(command, on: target)
            }
            .sheet(item: $creationRequest) { request in
                SomebodyNewSheet(item: request.item, closest: request.closest)
                    .environment(model)
            }
            .reportsModal(creationRequest != nil)
            .sheet(item: $factRequest) { request in
                FactEditorSheet(personID: request.person, mode: request.mode)
                    .environment(model)
            }
            .reportsModal(factRequest != nil)
            // One dialog, which is also the confirmation. The pane's two Keep buttons ask
            // for less because their label has already said which record survives.
            .confirmationDialog(
                mergeChoice.map { "Merge “\($0.firstName)” and “\($0.secondName)”?" } ?? "",
                isPresented: Binding(
                    get: { mergeChoice != nil }, set: { if !$0 { mergeChoice = nil } }),
                titleVisibility: .visible, presenting: mergeChoice
            ) { item in
                Button("Keep “\(item.firstName)”") {
                    model.mergePersons(item.candidate.person2, into: item.candidate.person1)
                }
                Button("Keep “\(item.secondName)”") {
                    model.mergePersons(item.candidate.person1, into: item.candidate.person2)
                }
            } message: { _ in
                Text(
                    "Names and facts are combined, and every relationship and evidence link "
                        + "moves to the record you keep. The other record is removed. You can "
                        + "undo it with ⌘Z.")
            }
            .reportsModal(mergeChoice != nil)
    }

    private func perform(_ command: ArchiveCommand, on target: ReviewTarget) {
        switch command {
        case .somebodyNew:
            guard let item = model.reviewItems.first(where: { $0.id == target.id }) else { return }
            creationRequest = CreationRequest(
                item: item, closest: model.closestCandidates(to: item.mention))
        case .mergeDuplicate:
            mergeChoice = model.duplicateItems.first { $0.id == target.id }
        case .acceptSuggestion:
            guard let item = model.factItems.first(where: { $0.id == target.id }),
                let top = item.suggestions.first
            else { return }
            factRequest = ReviewFactRequest(person: item.person.uid, mode: .fromEvidence(top))
        default:
            break
        }
    }
}

/// A pending somebody-new confirmation, holding the below-threshold candidates the sheet
/// will show. `Identifiable` so `.sheet(item:)` presents it — which, unlike
/// `isPresented:`, guarantees the content exists before the sheet is measured.
private struct CreationRequest: Identifiable {
    let id = UUID()
    let item: ReviewItem
    let closest: [SuggestedLink]
}

/// A fact editor opened from the worklist, on whichever person the row names.
private struct ReviewFactRequest: Identifiable {
    let id = UUID()
    let person: PersonID
    let mode: FactEditorSheet.Mode
}
