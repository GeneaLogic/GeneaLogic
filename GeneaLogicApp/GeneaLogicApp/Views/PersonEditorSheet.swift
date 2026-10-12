import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Adds or edits one `PersonName` on a concluded person — the sheet behind the
/// People-tab detail pane's **Names** section. A `nil` index adds a new name; a set
/// index edits the one at that position. Every commit writes through
/// `ArchiveModel.updatePerson`, so it's **undoable** (⌘Z).
///
/// Facts (person and couple) are edited in `FactEditorSheet`; keeping names here and
/// facts there matches the two detail sections and keeps each sheet single-purpose.
struct PersonEditorSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let personID: PersonID
    /// The array position being edited, or `nil` to add a new name.
    let index: Int?
    /// The existing name to prefill from when editing.
    let existing: PersonName?

    @State private var nameType: NameType
    @State private var given: String
    @State private var surname: String
    @State private var fullName: String
    @State private var language: String
    @State private var script: String

    init(personID: PersonID, index: Int?, existing: PersonName?) {
        self.personID = personID
        self.index = index
        self.existing = existing
        _nameType = State(initialValue: existing?.type ?? .birth)
        _given = State(initialValue: existing?.given ?? "")
        _surname = State(initialValue: existing?.surname ?? "")
        _fullName = State(initialValue: existing?.full ?? "")
        _language = State(initialValue: existing?.language ?? "")
        _script = State(initialValue: existing?.script ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            fields
            Divider()
            footer
        }
        .padding(Layout.sheetPadding)
        // Width-resizable, height fits the fields — matching the fact editor (F5).
        .presentationSizing(.fitted)
        .frame(
            minWidth: Layout.FormSheet.minWidth, idealWidth: Layout.FormSheet.idealWidth,
            maxWidth: Layout.FormSheet.maxWidth)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(index == nil ? "Add Name" : "Edit Name")
                .font(.headline)
            Text("A name this person is known by — birth, married, or an alias.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("Type") {
                Picker("Type", selection: $nameType) {
                    ForEach(NameType.pickerOptions(including: anchorNameType), id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledField("Given") {
                TextField("Given", text: $given, prompt: Text("given name(s)"))
                    .labelsHidden()
            }
            LabeledField("Surname") {
                TextField("Surname", text: $surname, prompt: Text("family name"))
                    .labelsHidden()
            }
            LabeledField("Full Name") {
                TextField("Full Name", text: $fullName, prompt: Text("optional, as written"))
                    .labelsHidden()
            }
            // A person's names are routinely in different languages/scripts (Chana /
            // Анна / Anna). The tag belongs on the name, not the person — and script is
            // what lets the matcher pick a phonetic keyer (slice 44h).
            LabeledField("Language") {
                TextField("Language", text: $language, prompt: Text("BCP 47, e.g. ru"))
                    .labelsHidden()
            }
            LabeledField("Script") {
                TextField("Script", text: $script, prompt: Text("ISO 15924, e.g. Cyrl"))
                    .labelsHidden()
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    /// A name needs some text (an empty name is a useless record, as in the New Person
    /// sheet).
    private var canSave: Bool {
        !given.trimmed.isEmpty || !surname.trimmed.isEmpty || !fullName.trimmed.isEmpty
    }

    private func save() {
        guard canSave else { return }

        // `full` is what every consumer displays, so it has to stay in step with the
        // parts. Two cases, distinguished by `hasDerivedFull` (the shared model rule):
        //
        // - The user typed a Full Name of their own ("Anna Maria von Meyer"): it
        //   carries information the parts don't, so it is written verbatim and must
        //   survive edits to Given/Surname untouched.
        // - The field still holds a `full` *we* derived (the common case — the Full
        //   Name field is prefilled from the record): re-derive it, or changing the
        //   surname would save the OLD full and the rename would be invisible
        //   everywhere while the fields say otherwise.
        //
        // `deriving` is the same rule the engine's `PersonDraft` and the CLI's
        // `person name set` use, so a name edited here is shaped identically to one
        // created anywhere else.
        let typedFull = fullName.trimmedNonEmpty
        let keepsPrefilledFull = typedFull == existing?.full && existing?.hasDerivedFull == true
        let name = PersonName.deriving(
            type: nameType,
            given: given.trimmedNonEmpty,
            surname: surname.trimmedNonEmpty,
            full: keepsPrefilledFull ? nil : typedFull,
            language: language.trimmedNonEmpty,
            script: script.trimmedNonEmpty)
        let actionName = index == nil ? "Add Name" : "Edit Name"
        model.updatePerson(of: personID, actionName: actionName) { person in
            if let index {
                guard index < person.names.count else { return }
                // Assign the fields this sheet **owns**, rather than replacing the
                // whole `PersonName`. A whole-value assignment silently drops every
                // field the editor doesn't know about: it destroyed `language` and
                // `script` the moment slice 44h added them (a name tagged via the CLI
                // lost both on any edit here, including a one-character typo fix), and
                // it would destroy the next field added the same way. Writing the
                // owned fields is opt-*in* — a new field is preserved by default, and
                // a new field this sheet should edit fails visibly by not editing.
                person.names[index].type = name.type
                person.names[index].given = name.given
                person.names[index].surname = name.surname
                person.names[index].full = name.full
                person.names[index].language = name.language
                person.names[index].script = name.script
            } else {
                person.names.append(name)
            }
        }
        dismiss()
    }

    // The type-picker options are anchored on the record's **original** type, not the
    // live selection, so an `.unknown(...)` value authored elsewhere stays offered even
    // after the user tries a known case (see `OpenVocabulary.pickerOptions`). For an add
    // there's no existing record, so the anchor is the default known case.
    private var anchorNameType: NameType { existing?.type ?? .birth }
}
