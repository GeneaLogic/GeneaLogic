import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The single editor behind every fact in the People-tab detail's **Facts** timeline —
/// a person's own facts *and* a couple's marriage/divorce/annulment (slice 43b). The
/// user sees one unified list and one "Add Fact…" button; the **type** decides where the
/// record is stored:
///
/// - A **person** type (birth, death, residence, …) writes to `Person.facts` via
///   `updatePerson`.
/// - A **couple** type (marriage, divorce, annulment — `FactType.coupleCases`) writes to
///   a couple `Relationship.facts` via `updateRelationship` (ARCHITECTURE §4.5 — a couple
///   fact belongs to the pairing, never duplicated onto a spouse). The "With" control
///   picks the spouse: an existing couple partner, **any other existing person** (a
///   couple relationship is created on save if one doesn't exist), or a **brand-new
///   person** minted inline (slice 43c). Creating the relationship/person and recording
///   the fact happen as one grouped, undoable step.
///
/// Every commit is undoable (⌘Z) through the model's snapshot-restore / redelete paths.
/// This is deliberately the one home for fact editing so the Facts list, the Add button,
/// and the edit sheet all agree; names stay in `PersonEditorSheet`.
struct FactEditorSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let personID: PersonID
    let mode: Mode
    /// Called with the fact an edit wrote, so its row can take focus back (79b).
    let onSaved: ((PersonFact) -> Void)?

    /// What the sheet is doing, and (when editing) the record + store it targets.
    enum Mode {
        /// Add a new fact — person or couple, decided by the type the user picks.
        case add
        /// Edit an existing `Person.facts[index]`.
        case editPerson(index: Int, existing: PersonFact)
        /// Edit an existing couple fact — `Relationship.facts[index]` on `relationshipID`,
        /// with the partner's display label for the header (`nil` if the spouse is unnamed
        /// or deleted). The partner is fixed here (editing a fact never re-homes it), so
        /// the "With" picker is not shown.
        case editCouple(
            relationshipID: RelationshipID, index: Int, existing: PersonFact, partner: String?)
        /// Promote linked-artifact evidence into a *new* fact (slice 42c): fields
        /// prefilled from the suggestion, the saved fact citing its `EvidenceLink`. A
        /// person type records a person fact; a **couple** type (e.g. a marriage event)
        /// records a couple fact, with the spouse pre-suggested from the source artifact
        /// (slice 43c).
        case fromEvidence(FactSuggestion)
    }

    @State private var factType: FactType
    @State private var dateText: String
    @State private var placeText: String
    @State private var valueText: String
    /// The chosen spouse for a new couple-type fact (add / from-evidence). `nil` until
    /// defaulted in `onAppear`; not used by the edit modes.
    @State private var partnerChoice: CouplePartnerChoice?
    /// The subject's existing couple relationships, resolved **once** in `onAppear` (rather
    /// than re-querying the index on every render) — the "With" menu's first-class options.
    @State private var partners: [PartnerOption] = []
    /// Other people the **source artifact** cites (from-evidence couple mode), as quick
    /// "With" options so the spouse named on the record is one click away without hunting
    /// through "Other person…". Excludes the subject and anyone already a partner (they're
    /// listed under `partners`). Resolved once in `onAppear`.
    @State private var evidenceCandidates: [PersonOption] = []
    /// Linked people the source record explicitly marks with the **spouse** role — the
    /// strongest default hint. Not used to *filter* the candidate menu (roles are often
    /// left at the default), only to pre-select when exactly one is present.
    @State private var recordSpouseIDs: [PersonID] = []
    /// Whether the "Other person…" partner picker sheet is presented.
    @State private var isPickingPartner = false

    /// One existing-partner "With" option: a couple relationship, its partner's person id
    /// (to dedupe an "Other person…" pick back onto it), and a display label.
    private struct PartnerOption: Identifiable {
        let id: RelationshipID
        let partnerID: PersonID
        let label: String
    }

    /// One person "With" option not backed by an existing relationship — a person the
    /// source record cites (a relationship is created on save if picked).
    private struct PersonOption: Identifiable {
        let id: PersonID
        let label: String
    }

    init(personID: PersonID, mode: Mode, onSaved: ((PersonFact) -> Void)? = nil) {
        self.personID = personID
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .add:
            _factType = State(initialValue: .birth)
            _dateText = State(initialValue: "")
            _placeText = State(initialValue: "")
            _valueText = State(initialValue: "")
        case .editPerson(_, let existing), .editCouple(_, _, let existing, _):
            _factType = State(initialValue: existing.type)
            _dateText = State(initialValue: existing.date ?? "")
            _placeText = State(initialValue: existing.place ?? "")
            _valueText = State(initialValue: existing.value ?? "")
        case .fromEvidence(let suggestion):
            _factType = State(initialValue: suggestion.suggestedType)
            _dateText = State(initialValue: suggestion.prefillDate ?? "")
            _placeText = State(initialValue: suggestion.prefillPlace ?? "")
            _valueText = State(initialValue: suggestion.prefillValue ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if case .fromEvidence(let suggestion) = mode {
                evidenceSource(suggestion)
            }
            FactFormFields(
                factType: $factType, dateText: $dateText, placeText: $placeText,
                valueText: $valueText, typeOptions: typeOptions)
            partnerField
            Divider()
            footer
        }
        .padding(Layout.sheetPadding)
        .presentationSizing(.fitted)
        // A `minHeight` floor (no `idealHeight`, which would *cap* the fit): the couple-
        // capable modes reserve enough height that revealing the "With" field mid-sheet
        // never clips the footer, while taller static modes (`.fromEvidence`, with its
        // long caption + evidence rows) still fit fully via `.fitted`.
        .frame(
            minWidth: Layout.FormSheet.minWidth, idealWidth: Layout.FormSheet.idealWidth,
            maxWidth: Layout.FormSheet.maxWidth,
            minHeight: minSheetHeight
        )
        .onAppear {
            // Resolve the "With" options once: existing partners, plus the people the
            // source record cites (from-evidence). Then default the selection (a single
            // record-spouse or the first partner) so a couple fact has a target without
            // hunting.
            partners = loadPartnerOptions()
            let evidence = loadEvidenceContext()
            evidenceCandidates = evidence.candidates
            recordSpouseIDs = evidence.spouseIDs
            if partnerChoice == nil { partnerChoice = defaultPartnerChoice() }
        }
        .sheet(isPresented: $isPickingPartner) {
            CouplePartnerPickerSheet(subjectID: personID) { pick in
                partnerChoice = resolvePartnerPick(pick)
            }
            .environment(model)
        }
    }

    /// A stable minimum height per mode. `.presentationSizing(.fitted)` sizes the sheet
    /// to its content *once* at open and doesn't regrow when picking a type reveals the
    /// Value or "With" field mid-sheet — so each mode reserves enough height up front that
    /// revealing those never clips the header/footer (slices 43b/44i). The person-only
    /// edit mode stays compact (it can still reveal a Value/Custom-Type row).
    private var minSheetHeight: CGFloat {
        switch mode {
        case .editPerson: return Layout.FormSheet.compactMinHeight
        case .add, .editCouple, .fromEvidence: return Layout.FormSheet.minHeight
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch mode {
        case .add: return "Add Fact"
        case .editPerson: return "Edit Fact"
        case .editCouple: return "Edit Relationship Fact"
        case .fromEvidence: return "Record Fact from Evidence"
        }
    }

    private var subtitle: String {
        switch mode {
        case .add:
            return "A fact about this person — or a marriage/divorce with a partner."
        case .editPerson:
            return "A concluded fact about this person, such as a birth or residence."
        case .editCouple(_, _, _, let partner):
            return partner.map { "A marriage, divorce, or annulment with \($0)." }
                ?? "A marriage, divorce, or annulment for this couple."
        case .fromEvidence:
            return
                "This evidence comes from an artifact that names this person, but the artifact's records aren't automatically about them. Confirm the fact type and value before recording."
        }
    }

    /// The "from evidence" context row: the source value and citing artifact, shown
    /// read-only above the editable fields (slice 42c).
    private func evidenceSource(_ suggestion: FactSuggestion) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Evidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(suggestion.evidenceLine)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if let artifactTitle = suggestion.artifactTitle {
                GridRow {
                    Text("Source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(artifactTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Partner field (couple types)

    /// Whether the current type is a couple fact (marriage/divorce/annulment).
    private var isCoupleType: Bool { FactType.coupleCases.contains(factType) }

    /// Whether the "With" picker is shown: only when *adding* a couple fact (add or from-
    /// evidence). The edit modes target a fixed record, so the partner can't be changed.
    private var showsPartnerPicker: Bool {
        switch mode {
        case .add, .fromEvidence: return isCoupleType
        case .editPerson, .editCouple: return false
        }
    }

    /// The subject's couple relationships, as first-class "With" options. Called **once**
    /// from `onAppear` into the `partners` state.
    private func loadPartnerOptions() -> [PartnerOption] {
        model.relationships(of: personID)
            .filter { $0.type == .couple }
            .map { relationship in
                let otherID = relationship.other(from: personID) ?? relationship.person1Uid
                let summary = model.persons.first { $0.uid == otherID }
                let label =
                    summary == nil ? "Unknown person" : (summary?.displayName ?? "Unnamed person")
                return PartnerOption(id: relationship.uid, partnerID: otherID, label: label)
            }
    }

    /// Resolves the from-evidence "With" context in one pass over the source artifact's
    /// links (couple mode only): the **candidate** menu options and the subset the record
    /// marks with the **spouse** role. A real marriage record names the couple **and**
    /// parents/witnesses, so rather than auto-guessing we surface every other linked person
    /// as a quick pick; the spouse role (when set) only sharpens the *default*, never
    /// filters the list. Candidates exclude the subject, anyone already a partner (listed
    /// under `partners`), and dangling links to deleted persons; both are deduped. Spouse
    /// ids are kept even for existing partners (so a marked-spouse partner still defaults),
    /// but only for persons that still exist. Empty for non-couple/non-evidence.
    private func loadEvidenceContext() -> (candidates: [PersonOption], spouseIDs: [PersonID]) {
        guard case .fromEvidence(let suggestion) = mode, isCoupleType else { return ([], []) }
        let roleByRef = Dictionary(
            (model.fullArtifact(suggestion.artifactID)?.personsMentioned ?? [])
                .map { ($0.localRef, $0.role) },
            uniquingKeysWith: { first, _ in first })
        let partnerIDs = Set(partners.map(\.partnerID))
        let byID = Dictionary(
            model.persons.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<PersonID> = []
        var candidates: [PersonOption] = []
        var spouseIDs: [PersonID] = []
        for link in model.artifactLinks(for: suggestion.artifactID) {
            let pid = link.personUid
            guard pid != personID else { continue }
            if roleByRef[link.personMentionRef] == .spouse, byID[pid] != nil,
                !spouseIDs.contains(pid)
            {
                spouseIDs.append(pid)
            }
            guard seen.insert(pid).inserted, !partnerIDs.contains(pid), let summary = byID[pid]
            else { continue }
            candidates.append(PersonOption(id: pid, label: summary.displayName ?? "Unnamed person"))
        }
        return (candidates, spouseIDs)
    }

    /// The default "With" selection, most-specific first:
    /// 1. the person the record explicitly marks as **spouse** (when exactly one), else
    /// 2. the record's **only** other named person (when the subject has no partner), else
    /// 3. the subject's first existing partner (if any).
    /// When a record names several people with no spouse role set, it's left unset — they're
    /// all listed in the menu instead. `resolvePartnerPick` collapses a spouse who is already
    /// a partner back onto that relationship.
    private func defaultPartnerChoice() -> CouplePartnerChoice? {
        if recordSpouseIDs.count == 1, let spouse = recordSpouseIDs.first {
            return resolvePartnerPick(.existing(spouse))
        }
        if partners.isEmpty, evidenceCandidates.count == 1, let only = evidenceCandidates.first {
            return .existingPerson(only.id)
        }
        return partners.first.map { .relationship($0.id) }
    }

    /// Maps an "Other person…" pick to a `CouplePartnerChoice`. An existing person who is
    /// **already** a couple partner collapses back onto that relationship (no duplicate);
    /// otherwise a relationship is created on save. A new person is minted on save.
    private func resolvePartnerPick(_ pick: PartnerPick) -> CouplePartnerChoice {
        switch pick {
        case .existing(let pid):
            if let option = partners.first(where: { $0.partnerID == pid }) {
                return .relationship(option.id)
            }
            return .existingPerson(pid)
        case .new(let given, let surname):
            return .newPerson(given: given, surname: surname)
        }
    }

    /// The label for the current "With" selection, or `nil` when nothing is chosen yet.
    private var partnerChoiceLabel: String? {
        switch partnerChoice {
        case .relationship(let rid):
            return partners.first { $0.id == rid }?.label
        case .existingPerson(let pid):
            return model.persons.first { $0.uid == pid }?.displayName ?? "Unnamed person"
        case .newPerson(let given, let surname):
            let joined = [given, surname]
                .compactMap { $0?.trimmedNonEmpty }
                .joined(separator: " ")
            return joined.isEmpty ? "New person" : "\(joined) (new)"
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private var partnerField: some View {
        if showsPartnerPicker {
            LabeledField("With") {
                Menu {
                    ForEach(partners) { option in
                        Button(option.label) { partnerChoice = .relationship(option.id) }
                    }
                    if !evidenceCandidates.isEmpty {
                        Section("Named on this record") {
                            ForEach(evidenceCandidates) { candidate in
                                Button(candidate.label) {
                                    partnerChoice = .existingPerson(candidate.id)
                                }
                            }
                        }
                    }
                    if !partners.isEmpty || !evidenceCandidates.isEmpty { Divider() }
                    Button("Other person…") { isPickingPartner = true }
                } label: {
                    Text(partnerChoiceLabel ?? "Choose…")
                }
                .fixedSize()
            }
        }
    }

    // MARK: - Footer

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

    /// A fact needs a non-empty type (the "Other…" custom field can be left blank) —
    /// and a *new couple* fact also needs a spouse to attach to (so it can't be saved
    /// until the "With" picker has a selection).
    private var canSave: Bool {
        guard !factType.rawValue.trimmed.isEmpty else { return false }
        if showsPartnerPicker { return partnerChoice != nil }
        return true
    }

    // MARK: - Type options

    /// The picker's fact types, scoped by mode so you can't accidentally convert a stored
    /// fact between the person and couple stores by editing its type:
    /// - **add**/**fromEvidence** offer everything (the type chooses the store — a from-
    ///   evidence marriage can become a proper couple fact, slice 43c).
    /// - **editPerson** offers person types only (+ the record's own type, so a legacy
    ///   couple-typed person fact stays selectable).
    /// - **editCouple** offers couple types only (+ the record's own type).
    private var typeOptions: [FactType] {
        switch mode {
        case .add:
            return FactType.pickerOptions(including: .birth)
        case .editPerson(_, let existing):
            return FactType.pickerOptions(from: FactType.personCases, including: existing.type)
        case .editCouple(_, _, let existing, _):
            return FactType.pickerOptions(from: FactType.coupleCases, including: existing.type)
        case .fromEvidence(let suggestion):
            return FactType.pickerOptions(including: suggestion.suggestedType)
        }
    }

    // MARK: - Save

    private func save() {
        guard canSave else { return }
        let fact = FactForm.build(
            type: factType, date: dateText, place: placeText, value: valueText,
            supportedByLinks: existingLinks)
        switch mode {
        case .add:
            if isCoupleType {
                saveCoupleFact(fact, actionName: "Add Relationship Fact")
            } else {
                model.updatePerson(of: personID, actionName: "Add Fact") { $0.facts.append(fact) }
            }
        case .fromEvidence:
            if isCoupleType {
                saveCoupleFact(fact, actionName: "Record Relationship Fact from Evidence")
            } else {
                model.updatePerson(of: personID, actionName: "Record Fact from Evidence") {
                    $0.facts.append(fact)
                }
            }
        // An edit finds its fact by value, starting at its index, in the record the write
        // reads: a list that shifted since edits this fact or nothing (79b).
        case .editPerson(let index, let existing):
            model.updatePerson(of: personID, actionName: "Edit Fact") { person in
                guard let position = person.facts.position(of: existing, near: index)
                else { return }
                person.facts[position] = fact
            }
            onSaved?(fact)
        case .editCouple(let rid, let index, let existing, _):
            model.updateRelationship(of: rid, actionName: "Edit Relationship Fact") {
                relationship in
                guard let position = relationship.facts.position(of: existing, near: index)
                else { return }
                relationship.facts[position] = fact
            }
            onSaved?(fact)
        }
        dismiss()
    }

    /// Routes a new couple fact to the right undoable model path per the "With" selection:
    /// append to an existing relationship, create a relationship with an existing person
    /// (`ArchiveModel.recordCoupleFact`), or mint the person + relationship + fact together
    /// (slice 43c). Named distinctly from the model method it delegates to.
    private func saveCoupleFact(_ fact: PersonFact, actionName: String) {
        switch partnerChoice {
        case .relationship(let rid):
            model.updateRelationship(of: rid, actionName: actionName) { $0.facts.append(fact) }
        case .existingPerson(let pid):
            model.recordCoupleFact(
                between: personID, and: pid, fact: fact, actionName: actionName)
        case .newPerson(let given, let surname):
            model.createPersonRelateAndRecord(
                subject: personID, given: given, surname: surname, fact: fact,
                actionName: actionName)
        case nil:
            break  // `canSave` prevents reaching here.
        }
    }

    /// The edited/promoted fact's evidence support, carried through untouched (the editor
    /// doesn't manage links). An add starts with none; a promoted fact cites its link.
    private var existingLinks: [EvidenceLinkID] {
        switch mode {
        case .editPerson(_, let existing), .editCouple(_, _, let existing, _):
            return existing.supportedByLinks
        case .fromEvidence(let suggestion):
            return [suggestion.link]
        case .add:
            return []
        }
    }
}

/// Identifiable wrapper so a fact add-or-edit request (person *or* couple — slice 43b)
/// can drive `.sheet(item:)`. Lives beside the sheet it presents rather than inside one
/// caller, since 45i gave it a second one (the Review section's facts lane).
struct FactEditorRequest: Identifiable {
    let id = UUID()
    let mode: FactEditorSheet.Mode
    /// Whether the row it edits had keyboard focus, which comes back to it (79b).
    var returnsFocus = false
}

/// How a couple fact's spouse is chosen in `FactEditorSheet` (slice 43c). A couple fact
/// rides a couple `Relationship`; the user can reuse an existing partner relationship,
/// pick another existing person (a relationship is created on save), or mint a brand-new
/// spouse inline (person + relationship + fact created together, one grouped undo).
enum CouplePartnerChoice: Equatable {
    case relationship(RelationshipID)
    case existingPerson(PersonID)
    case newPerson(given: String?, surname: String?)
}
