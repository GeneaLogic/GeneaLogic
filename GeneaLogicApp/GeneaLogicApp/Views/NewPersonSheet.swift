import GeneaLogicArchive
import SwiftUI

/// Creates a concluded person from a given/surname pair — the New Person sheet
/// behind the People tab's + button. Uses `PersonDraft`'s convenience path (a
/// single `.birth`-typed name); richer names/facts are added afterward in the
/// detail pane. The create is undoable (⌘Z) and auto-selects the new person.
struct NewPersonSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var given = ""
    @State private var surname = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Person")
                .font(.headline)

            Form {
                TextField("Given name", text: $given)
                TextField("Surname", text: $surname)
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(Layout.sheetPadding)
        .frame(
            minWidth: Layout.FormSheet.minWidth,
            idealWidth: Layout.FormSheet.idealWidth,
            maxWidth: Layout.FormSheet.maxWidth
        )
        .presentationSizing(.fitted)
    }

    /// Require at least one of given/surname — a person with no name at all is a
    /// useless record (the engine allows it, but the sheet shouldn't invite it).
    private var canCreate: Bool {
        !given.trimmed.isEmpty || !surname.trimmed.isEmpty
    }

    private func create() {
        guard canCreate else { return }
        model.createPerson(given: given.trimmedNonEmpty, surname: surname.trimmedNonEmpty)
        dismiss()
    }
}
