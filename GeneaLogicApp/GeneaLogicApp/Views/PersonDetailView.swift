import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The People-tab detail pane. Shows — and **edits** — a concluded person's names
/// and facts: each section has an Add affordance, tap-a-row-to-edit, and a per-row
/// remove, all committed through `ArchiveModel.updatePerson` and so **undoable** (⌘Z).
/// This is the People analog of the artifact inspector's Events & Places / Persons
/// Mentioned sections. Loads the full `Person` off `mutationVersion`, so an edit,
/// remove, or delete-undo refreshes it.
struct PersonDetailView: View {
    @Environment(ArchiveModel.self) private var model
    let personID: PersonID

    @State private var person: Person?
    /// The artifacts that cite this person — the "Sources" section (slice 42b).
    /// Loaded alongside `person` and reloaded off `mutationVersion`, so an unlink
    /// (here or on the artifact side) refreshes it.
    @State private var sources: [PersonSource] = []
    /// Promotable evidence from the linked artifacts — the "Suggested Facts" section
    /// (slice 42c). Assembled in the same pass as `sources` (both read the linked
    /// artifacts' full records) and reloaded off `mutationVersion`.
    @State private var suggestions: [FactSuggestion] = []
    /// The name add-or-edit request driving the name editor sheet, or `nil`.
    @State private var nameEditorRequest: NameEditorRequest?
    /// The fact add-or-edit request driving the fact editor sheet (person *or* couple
    /// fact — slice 43b), or `nil`.
    @State private var factEditorRequest: FactEditorRequest?
    /// This person's relationships, resolved to display rows (relative name + role).
    /// Loaded alongside `person` and reloaded off `mutationVersion` (slice 43).
    @State private var relatives: [RelativeRow] = []
    /// Whether the "Add Relationship" sheet is presented.
    @State private var isAddingRelationship = false
    /// Edges this person's sources state that `conclusions/` doesn't assert (slice 45l).
    /// Loaded with `person` and reloaded off `mutationVersion`, so recording one — or
    /// resolving one more mention anywhere — moves the list.
    @State private var relationshipSuggestions: [RelationshipReviewItem] = []

    /// The dangling relationship whose "Replace Person…" picker is up (slice 44g), or
    /// `nil`. Carries the endpoint being replaced, since that's what identifies which
    /// side of the relationship to rewrite.
    @State private var replacingEndpoint: EndpointReplacement?

    var body: some View {
        Group {
            if let person {
                content(person)
            } else {
                ContentUnavailableView(
                    "Person Not Found", systemImage: "person.slash",
                    description: Text("This person may have been deleted."))
            }
        }
        // Reload when the selected person changes *or* any mutation commits (an edit,
        // a remove, a delete-undo restoring this person, or an unlink from a source).
        .task(id: reloadKey) {
            let loaded = model.fullPerson(personID)
            person = loaded
            // Fetch this person's relationships once and feed both consumers below.
            let relationships = model.relationships(of: personID)
            (sources, suggestions) = model.linkedEvidence(
                for: personID,
                recordedFacts: SuggestedFacts.recordedFacts(
                    of: loaded, relationships: relationships))
            relatives = loadRelatives(from: relationships)
            relationshipSuggestions = model.suggestedRelationships(for: personID)
        }
        .sheet(item: $nameEditorRequest) { request in
            PersonEditorSheet(personID: personID, index: request.index, existing: request.existing)
                .environment(model)
        }
        .sheet(item: $factEditorRequest) { request in
            FactEditorSheet(personID: personID, mode: request.mode)
                .environment(model)
        }
        .sheet(item: $replacingEndpoint) { request in
            ReplacePersonSheet(
                subjectID: personID, roleDescription: request.roleDescription
            ) { replacement in
                model.replaceRelationshipEndpoint(
                    request.relationshipID, replacing: request.missingID, with: replacement)
            }
            .environment(model)
        }
        .sheet(isPresented: $isAddingRelationship) {
            if let person {
                RelationshipEditorSheet(
                    subjectID: personID, subjectName: Self.displayName(person)
                )
                .environment(model)
            }
        }
    }

    private var reloadKey: String { "\(personID.raw)-\(model.mutationVersion)" }

    @ViewBuilder
    private func content(_ person: Person) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(Self.displayName(person))
                    .font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)

                namesSection(person)
                factsSection(person)
                relationshipsSection(person)
                // Directly under Relationships, mirroring how Suggested Facts sits under
                // Facts — the pairing is what makes both readable as "recorded / offered".
                suggestedRelationshipsSection()
                suggestedFactsSection()
                sourcesSection()
                identifiersSection(person)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    // Sections mirror `ArtifactDetailView`'s style — a `VStack` with a primary
    // `.headline` header (not a `List`/`Form` `Section`, which is inert here) — so
    // the two detail panes read alike.

    @ViewBuilder
    private func namesSection(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Names")
                    .font(.headline)
                Spacer()
                // Direct-action button (opens the editor sheet) — no chevron, like the
                // artifact "Add Person…" affordance (F8).
                Button {
                    nameEditorRequest = NameEditorRequest(index: nil, existing: nil)
                } label: {
                    AddAffordanceLabel(title: "Add Name…", systemImage: "person.badge.plus")
                }
                .buttonStyle(.plain)
            }

            if person.names.isEmpty {
                Text("No names recorded. Use Add Name… to record one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(person.names.enumerated()), id: \.offset) { index, name in
                        AssertionRow(
                            title: Self.nameLine(name),
                            subtitle: Self.nameSubtitle(name),
                            icon: "person",
                            onEdit: {
                                nameEditorRequest = NameEditorRequest(index: index, existing: name)
                            }
                        ) { removeName(at: index) }
                    }
                }
            }
        }
    }

    /// The **Facts** timeline: this person's own facts (`Person.facts`) *and* their
    /// couple facts (marriage/divorce/annulment), projected from each partner
    /// relationship and tagged with the partner (slice 43b). The couple fact stays stored
    /// on the `Relationship` (§4.5) — this is a read projection, and editing/removing a
    /// couple row routes back to `updateRelationship`. Sorted into one date-ordered
    /// timeline (undated last). "Add Fact…" opens the unified editor; picking a couple
    /// type there records against a chosen partner.
    @ViewBuilder
    private func factsSection(_ person: Person) -> some View {
        let rows = factRows(person)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Facts")
                    .font(.headline)
                Spacer()
                Button {
                    factEditorRequest = FactEditorRequest(mode: .add)
                } label: {
                    AddAffordanceLabel(title: "Add Fact…", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.plain)
            }

            if rows.isEmpty {
                Text("No facts recorded. Use Add Fact… to record one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        AssertionRow(
                            title: row.fact.type.displayName,
                            subtitle: row.subtitle,
                            icon: "calendar",
                            onEdit: { factEditorRequest = FactEditorRequest(mode: row.editMode) }
                        ) { removeFactRow(row) }
                    }
                }
            }
        }
    }

    /// Builds the merged, date-sorted Facts timeline: the person's own facts plus their
    /// couple facts (from partner relationships), each carrying the store it edits back
    /// to. Undated/unparseable dates sort last; a composite id keeps the order stable
    /// across reloads.
    private func factRows(_ person: Person) -> [FactRow] {
        var rows: [FactRow] = []
        for (index, fact) in person.facts.enumerated() {
            rows.append(
                FactRow(
                    id: "person#\(index)", fact: fact, subtitle: Self.factDetail(fact),
                    source: .person(index: index)))
        }
        for relative in relatives where relative.role == .partner {
            let partner = relative.otherExists ? relative.otherName : nil
            for (index, fact) in relative.facts.enumerated() {
                rows.append(
                    FactRow(
                        id: "\(relative.relationshipID.raw)#\(index)", fact: fact,
                        subtitle: Self.coupleFactDetail(fact, partner: partner),
                        source: .couple(relationshipID: relative.relationshipID, index: index),
                        partner: partner))
            }
        }
        return rows.sorted { lhs, rhs in
            // Order by the EDTF chronological bound (masked/approximate dates sort
            // correctly, unlike a raw-string compare); undated/unparseable last; a
            // composite-id tiebreak keeps the order stable across reloads.
            let l = Self.factSortBound(lhs.fact)
            let r = Self.factSortBound(rhs.fact)
            switch (l, r) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false  // undated → after a dated one
            case (_?, nil): return true  // dated → before an undated one
            default: return lhs.id < rhs.id
            }
        }
    }

    /// A fact's chronological sort bound, or `nil` when its date is absent or not
    /// parseable as EDTF (those facts still show, at the end of the timeline).
    private static func factSortBound(_ fact: PersonFact) -> EDTFBound? {
        fact.date?.trimmedNonEmpty.flatMap { EDTFDate.parse($0)?.sortBound }
    }

    /// The **Relationships** section (slice 43): this person's parents, children, and
    /// partners. Each row shows the relative's name + their role *from this person's
    /// perspective* (Parent / Child / Partner), taps through to that person, and can be
    /// removed. "Add Relationship…" opens the perspective-based editor. A relationship
    /// whose other endpoint was deleted (§2.3, no cascade) still shows, as "Unknown
    /// person," so it stays visible and removable. Couple *facts* (marriage/divorce) are
    /// not shown here — they live in the Facts timeline (slice 43b).
    @ViewBuilder
    private func relationshipsSection(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Relationships")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingRelationship = true
                } label: {
                    AddAffordanceLabel(
                        title: "Add Relationship…", systemImage: "person.2.badge.plus")
                }
                .buttonStyle(.plain)
            }

            if relatives.isEmpty {
                Text("No relationships recorded. Use Add Relationship… to link a relative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(relatives) { relative in
                        RelativeRowView(
                            relative: relative,
                            onNavigate: { model.navigateToPerson(relative.otherID) },
                            onRemove: { model.deleteRelationship(relative.relationshipID) },
                            onSetQualifier: {
                                model.setParentChildQualifier(relative.relationshipID, to: $0)
                            },
                            onReplacePerson: {
                                replacingEndpoint = EndpointReplacement(
                                    relationshipID: relative.relationshipID,
                                    missingID: relative.otherID,
                                    roleDescription: relative.role.label.lowercased())
                            })
                    }
                }
            }
        }
    }

    /// The **Sources** section: which artifact mentions cite this person, with a jump
    /// back to the citing artifact and an Unlink — the read-side mirror of the artifact
    /// inspector's resolved-mention chip (slice 42b). Read-only over `personLinks(for:)`;
    /// Unlink is the *only* mutation, routed through the shared `unlinkMention`.
    @ViewBuilder
    private func sourcesSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)

            if sources.isEmpty {
                Text(
                    "No sources yet. Resolve a person mention in an artifact to link "
                        + "evidence here."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sources) { source in
                        PersonSourceRow(
                            source: source,
                            onNavigate: { model.navigateToArtifact(source.artifactID) },
                            onUnlink: { model.unlinkMention(source.linkID) },
                            onAddName: source.nameAsRecorded.flatMap { recorded in
                                recordedNameIsNew(recorded) ? { addRecordedName(recorded) } : nil
                            }
                        )
                    }
                }
            }
        }
    }

    /// Whether `recorded` (a mention's name-as-recorded) is not yet one of this person's
    /// names — the gate for offering "Add as name" on a Sources row. Compared trimmed and
    /// case-insensitively against each name's resolved text, so an exact re-spelling isn't
    /// re-offered while a genuinely different form (a Yiddish spelling, a married name) is.
    private func recordedNameIsNew(_ recorded: String) -> Bool {
        let needle = recorded.trimmed.lowercased()
        guard !needle.isEmpty else { return false }
        let existing = (person?.names ?? []).compactMap { $0.resolvedText?.lowercased() }
        return !existing.contains(needle)
    }

    /// Opens the name editor **prefilled** with a mention's recorded name (as the full
    /// name, type defaulting to birth) so the human sets the type and given/surname split
    /// before it's added — the name-side analog of promoting a suggested fact. `index:
    /// nil` makes it an *add* (see `PersonEditorSheet`); the write is undoable.
    private func addRecordedName(_ recorded: String) {
        nameEditorRequest = NameEditorRequest(
            index: nil, existing: PersonName(type: .birth, full: recorded.trimmed))
    }

    /// The **Suggested Facts** section (slice 42c): promotable evidence from the linked
    /// artifacts (their events + a mention's recorded age). Each row's **Apply…** opens
    /// the person editor prefilled from the evidence — the human confirms the fact type
    /// and corrects the value (§2.3, never auto-copied), and the saved fact cites the
    /// supporting link. Hidden entirely when there's no evidence to promote.
    @ViewBuilder
    private func suggestedFactsSection() -> some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested Facts")
                    .font(.headline)
                Text(
                    "Evidence from linked sources. Review and confirm before recording — "
                        + "a source's records aren't automatically about this person."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions) { suggestion in
                        FactSuggestionRow(
                            suggestion: suggestion,
                            onRecord: { model.recordSuggestedFact(suggestion, for: personID) },
                            onApply: {
                                factEditorRequest = FactEditorRequest(
                                    mode: .fromEvidence(suggestion))
                            })
                    }
                }
            }
        }
    }

    /// The **Suggested Relationships** section (slice 45l): edges this person's own sources
    /// state that `conclusions/` doesn't yet assert.
    ///
    /// **It is here because its absence was the odd thing.** This pane already pairs Facts
    /// with Suggested Facts; Relationships standing alone read as *there is nothing here to
    /// promote*, which was false for exactly the person the slice was built for. Found in
    /// hand-testing, and the third filter over the one derivation — the lane and the artifact
    /// inspector are the other two, and none of them re-derive, so they cannot disagree about
    /// what is still owed.
    ///
    /// No confidence figure, like the lane: both endpoints were identified by a human, so
    /// nothing here was scored. What a reader weighs is which record says it, and whether
    /// that record **states** the edge or its roles only **imply** it.
    @ViewBuilder
    private func suggestedRelationshipsSection() -> some View {
        if !relationshipSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested Relationships")
                    .font(.headline)
                Text(
                    "Relationships your sources state about this person, not yet recorded "
                        + "as conclusions. Recording one cites the evidence it came from."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(relationshipSuggestions) { item in
                        PersonRelationshipSuggestionRow(
                            item: item,
                            // From *this* person's side, so the row reads as a statement
                            // about them rather than one they have to re-orient.
                            subject: personID,
                            onRecord: { model.confirmSuggestedRelationship(item) },
                            onDismiss: { model.dismissSuggestedRelationship(item) })
                    }
                }
            }
        }
    }

    /// Resolves this person's relationships into display rows (slice 43): each relative's
    /// name and their role *from this person's perspective*. Rows are sorted by role
    /// (Parents, then Partners, then Children) and then by name for a stable, readable
    /// order. The other endpoint is resolved against `model.persons` (the full list, not
    /// the search-filtered one): a **missing** person is a dangling relationship (§2.3,
    /// no cascade) and reads "Unknown person" with no jump; an **existing but unnamed**
    /// person reads "Unnamed person" and *stays navigable* — the two are distinguished by
    /// existence, not by whether a name resolved.
    private func loadRelatives(from relationships: [Relationship]) -> [RelativeRow] {
        let personsByID = Dictionary(
            model.persons.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })

        return
            relationships
            .map { relationship -> RelativeRow in
                let (otherID, role) = Self.roleOfOther(in: relationship, subject: personID)
                let summary = personsByID[otherID]
                return RelativeRow(
                    relationshipID: relationship.uid,
                    otherID: otherID,
                    otherName: summary?.displayName,
                    otherExists: summary != nil,
                    role: role,
                    facts: relationship.facts,
                    qualifier: relationship.facts.first {
                        FactType.parentChildCases.contains($0.type)
                    }?.type)
            }
            .sorted { lhs, rhs in
                if lhs.role.sortOrder != rhs.role.sortOrder {
                    return lhs.role.sortOrder < rhs.role.sortOrder
                }
                return (lhs.otherName ?? "") < (rhs.otherName ?? "")
            }
    }

    /// Determines the other endpoint and its role relative to `subject`, per the §4.5
    /// convention, read through `Relationship.parent` / `.child` rather than unpacked
    /// here. For `parent-child` the subject is the parent when it is that record's
    /// `parent`, and the child otherwise.
    private static func roleOfOther(in relationship: Relationship, subject: PersonID) -> (
        other: PersonID, role: RelativeRow.Role
    ) {
        // `other(from:)` is nil only when the subject isn't an endpoint at all, which
        // `relationships(of:)` shouldn't produce; fall back to `person1Uid` as before.
        let other = relationship.other(from: subject) ?? relationship.person1Uid
        switch relationship.type {
        case .couple:
            return (other, .partner)
        case .parentChild:
            // The §4.5 endpoint convention lives on `Relationship.parent` / `.child`.
            return relationship.parent == subject ? (other, .child) : (other, .parent)
        case .unknown(let raw):
            return (other, .other(raw))
        }
    }

    // MARK: - Mutations

    /// Removes the name at `index` (undoable). The bounds check lives inside the
    /// `updatePerson` closure, over the record at write time, so a stale index (from a
    /// concurrent edit/undo) is a no-op rather than a crash.
    private func removeName(at index: Int) {
        model.updatePerson(of: personID, actionName: "Remove Name") { person in
            guard index < person.names.count else { return }
            person.names.remove(at: index)
        }
    }

    /// Removes a Facts-timeline row, routing to the right store: a person fact through
    /// `updatePerson`, a couple fact through `updateRelationship` (both undoable). As with
    /// names, the bounds check lives inside the mutate closure, over the record at write
    /// time, so a stale index (from a concurrent edit/undo) is a no-op, not a crash.
    private func removeFactRow(_ row: FactRow) {
        switch row.source {
        case .person(let index):
            model.updatePerson(of: personID, actionName: "Remove Fact") { person in
                guard index < person.facts.count else { return }
                person.facts.remove(at: index)
            }
        case .couple(let relationshipID, let index):
            model.updateRelationship(of: relationshipID, actionName: "Remove Relationship Fact") {
                relationship in
                guard index < relationship.facts.count else { return }
                relationship.facts.remove(at: index)
            }
        }
    }

    @ViewBuilder
    private func identifiersSection(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identifiers")
                .font(.headline)
            LabeledContent("UID") {
                Text(person.uid.raw)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Formatting

    /// The person's display name, with this view's placeholder for a person who has
    /// none.
    ///
    /// The derivation itself is `Person.displayName` in `GeneaLogicModel` (slice
    /// 44c) — shared with the engine's `PersonSummary` and the CLI, so the pane
    /// title, the list row and `genea person show` can't disagree. Only the
    /// *placeholder* is a local choice.
    static func displayName(_ person: Person) -> String {
        person.displayName ?? "Unnamed person"
    }

    /// A single name rendered for a row: its resolved text, else an em dash.
    private static func nameLine(_ name: PersonName) -> String {
        name.resolvedText ?? "—"
    }

    /// The name-row subtitle: its type, plus a "ru/Cyrl" language/script tag when set
    /// (the same tag the artifact mention rows show, so the two don't drift).
    private static func nameSubtitle(_ name: PersonName) -> String {
        var parts = [name.type.displayName]
        if let tag = languageScriptTag(language: name.language, script: name.script) {
            parts.append(tag)
        }
        return parts.joined(separator: " · ")
    }

    /// The date (EDTF-glossed), place, and evidence-citation count under a fact type,
    /// or `nil` if none apply. The citation count makes a fact recorded from evidence
    /// (slice 42c) visibly evidence-backed rather than a bare assertion.
    static func factDetail(_ fact: PersonFact) -> String? {
        var parts: [String] = []
        if let value = fact.value?.trimmedNonEmpty {
            parts.append("“\(value)”")
        }
        if let date = fact.date?.trimmedNonEmpty {
            parts.append(EDTFDate.parse(date)?.humanDescription ?? date)
        }
        if let place = fact.place?.trimmedNonEmpty {
            parts.append(place)
        }
        let citations = fact.supportedByLinks.count
        if citations > 0 {
            parts.append("cited by \(citations) source\(citations == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The subtitle for a **couple** fact in the Facts timeline (slice 43b): the same
    /// date/place/citation detail as a person fact, plus a "with <partner>" tag so a
    /// projected marriage/divorce reads as shared. The partner name is `nil` when the
    /// other spouse is unnamed or deleted (§2.3) — the tag is simply omitted.
    static func coupleFactDetail(_ fact: PersonFact, partner: String?) -> String? {
        var parts: [String] = []
        if let base = factDetail(fact) { parts.append(base) }
        if let partner = partner?.trimmedNonEmpty { parts.append("with \(partner)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Identifiable wrapper so a dangling-endpoint repair can drive `.sheet(item:)`.
/// `missingID` is the deleted person the relationship still names — it's what tells
/// `replaceRelationshipEndpoint` which side to rewrite, preserving the §4.5 convention.
private struct EndpointReplacement: Identifiable {
    let id = UUID()
    let relationshipID: RelationshipID
    let missingID: PersonID
    let roleDescription: String
}

/// Identifiable wrapper so a name add-or-edit request can drive `.sheet(item:)`.
private struct NameEditorRequest: Identifiable {
    let id = UUID()
    let index: Int?
    let existing: PersonName?
}

/// One Suggested Relationships row on the person pane (slice 45l): the claim from this
/// person's side, which record it came from, and the two verbs.
///
/// **`sparkles`, like the Suggested Facts rows above it** — the two are the same kind of
/// offer (here is something your records say that your conclusions don't), and marking them
/// differently would imply a distinction that isn't there.
private struct PersonRelationshipSuggestionRow: View {
    @Environment(ArchiveModel.self) private var model
    let item: RelationshipReviewItem
    /// The person whose page this is — the referent of *their*.
    let subject: PersonID
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.phrase(from: subject))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let citation = item.leadCitation {
                    // Title and basis from **one** citation, never the archive-wide
                    // `isStated` beside an arbitrary title — see `RelationshipReviewItem`.
                    Text(
                        citation.basis == .stated
                            ? "Stated by \(citation.title)"
                            : "Implied by roles on \(citation.title)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Record", action: onRecord)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .help("Add this relationship to your conclusions (⌘Z to undo)")
                    Button("Not This", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Stop offering this relationship, here and in Review")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One row in the merged Facts timeline (slice 43b): a fact plus the store it edits back
/// to — `Person.facts` or a couple `Relationship.facts`. The `id` is a stable composite
/// so `ForEach` diffs rows across a `mutationVersion` reload.
private struct FactRow: Identifiable {
    let id: String
    let fact: PersonFact
    let subtitle: String?
    let source: Source
    /// The partner's display label for a couple row (for the couple editor's header);
    /// `nil` for a person fact or an unnamed/deleted partner.
    var partner: String? = nil

    /// Which store — and index — this row edits/removes.
    enum Source {
        case person(index: Int)
        case couple(relationshipID: RelationshipID, index: Int)
    }

    /// The editor mode that opens this row for editing, routed to the right store.
    var editMode: FactEditorSheet.Mode {
        switch source {
        case .person(let index):
            return .editPerson(index: index, existing: fact)
        case .couple(let relationshipID, let index):
            return .editCouple(
                relationshipID: relationshipID, index: index, existing: fact, partner: partner)
        }
    }
}

/// One resolved relationship shown in the person detail's Relationships section: the
/// other person, their role from the subject's perspective, and the relationship's uid
/// (for removal). `otherExists` is `false` when that person was deleted (§2.3, no
/// cascade — a dangling relationship); `otherName` is `nil` for a person that exists but
/// has no resolvable name (rendered "Unnamed person", still navigable).
private struct RelativeRow: Identifiable {
    let relationshipID: RelationshipID
    let otherID: PersonID
    let otherName: String?
    let otherExists: Bool
    let role: Role
    /// The relationship's own facts — for a **couple**, its marriage/divorce/annulment
    /// (slice 43b). Shown and edited inline under a partner row; empty (and unshown) for
    /// parent-child rows.
    let facts: [PersonFact]
    /// The **nature** of a parent-child link (slice 44f), derived from `facts`. `nil`
    /// is *unspecified* — deliberately not read as "biological".
    let qualifier: FactType?

    var id: RelationshipID { relationshipID }

    /// The other person's role relative to the subject. `.other` preserves an
    /// unrecognized relationship-type string so a future/foreign type still labels.
    enum Role: Equatable {
        case parent, child, partner, other(String)

        var label: String {
            switch self {
            case .parent: "Parent"
            case .child: "Child"
            case .partner: "Partner"
            case .other(let raw): raw
            }
        }

        var icon: String {
            switch self {
            case .parent: "arrow.up.circle"
            case .child: "arrow.down.circle"
            case .partner: "heart.circle"
            case .other: "person.circle"
            }
        }

        /// Groups the list: parents first, then partners, then children, then anything
        /// unrecognized — a familiar top-down family ordering.
        var sortOrder: Int {
            switch self {
            case .parent: 0
            case .partner: 1
            case .child: 2
            case .other: 3
            }
        }
    }
}

/// One Relationships row: the relative (tap to jump to their detail on the People tab),
/// their role, and a remove. Mirrors `PersonSourceRow`'s navigate-plus-remove chrome. A
/// dangling relationship (deleted other person) shows "Unknown person" with navigation
/// disabled but removal still live. Couple *facts* (marriage/divorce) aren't shown here —
/// they live in the Facts timeline (slice 43b).
private struct RelativeRowView: View {
    let relative: RelativeRow
    let onNavigate: () -> Void
    let onRemove: () -> Void
    /// Sets (or clears, with `nil`) the nature of a parent-child link.
    let onSetQualifier: (FactType?) -> Void
    /// Opens the picker that repoints this relationship at a person who still exists.
    /// Only offered while the row dangles.
    let onReplacePerson: () -> Void

    @State private var isHovering = false

    /// The other person was deleted (§2.3, no cascade) — nowhere to jump to. An
    /// *existing* but unnamed person is not dangling; it stays navigable.
    private var isDangling: Bool { !relative.otherExists }

    /// Label for the other person: their name, "Unnamed person" if they exist without
    /// one, or "Unknown person" if the relationship dangles onto a deleted person.
    private var otherLabel: String {
        if !relative.otherExists { return "Unknown person" }
        return relative.otherName ?? "Unnamed person"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: relative.role.icon)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onNavigate) {
                        HStack(spacing: 4) {
                            Text(otherLabel)
                                .fontWeight(.medium)
                            if !isDangling {
                                Image(systemName: "arrow.up.right")
                                    .imageScale(.small)
                            }
                        }
                        .foregroundStyle(isDangling ? Color.secondary : Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDangling)
                    .help(
                        isDangling
                            ? "This person's record was deleted"
                            : "Show this person on the People tab")

                    // Repairing beats removing: the relationship is still true, it just
                    // names someone who is gone (slice 44g).
                    if isDangling {
                        Button("Replace Person…", action: onReplacePerson)
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .help("Point this relationship at a person that still exists")
                    }
                }

                HStack(spacing: 4) {
                    Text(relative.role.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // The nature of a parent-child link is often learned after the link
                    // itself, so it is editable here as well as at creation time.
                    if relative.role == .parent || relative.role == .child {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        natureMenu
                    }
                }
            }
            Spacer(minLength: 0)
            RowRemoveButton(
                isHovering: isHovering, accessibilityLabel: "Remove relationship",
                help: "Remove this relationship (⌘Z to undo)", action: onRemove)
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Shown on every parent/child row, including unqualified ones — an always-present
    /// "Unspecified" is both discoverable and honest about what is (not) recorded.
    private var natureMenu: some View {
        Menu {
            Button("Unspecified") { onSetQualifier(nil) }
            Divider()
            ForEach(FactType.parentChildCases, id: \.self) { type in
                Button(type.natureLabel) { onSetQualifier(type) }
            }
        } label: {
            HStack(spacing: 2) {
                Text(relative.qualifier?.natureLabel ?? "Unspecified")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(relative.qualifier == nil ? Color.secondary : Color.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("The nature of this parent-child link")
    }
}

/// One Sources row: the citing artifact (tap to jump to it on the Artifacts tab) and
/// the mention's name-as-recorded, with an **Unlink**. The People-side mirror of the
/// artifact inspector's resolved-mention chip (slice 42b). A dangling link (deleted
/// artifact) shows "Unknown artifact" with navigation disabled but Unlink still live.
private struct PersonSourceRow: View {
    let source: PersonSource
    let onNavigate: () -> Void
    let onUnlink: () -> Void
    /// Add the mention's name-as-recorded to the person as a name — `nil` when there's
    /// no recorded name, or it's already one of the person's names (slice 44i).
    let onAddName: (() -> Void)?

    @State private var isHovering = false

    /// The citing artifact was deleted (§2.3, no cascade): show the link but disable
    /// the jump — there's nowhere to go.
    private var isDangling: Bool { source.artifactTitle == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Button(action: onNavigate) {
                    HStack(spacing: 4) {
                        Text(source.artifactTitle ?? "Unknown artifact")
                            .fontWeight(.medium)
                        if !isDangling {
                            Image(systemName: "arrow.up.right")
                                .imageScale(.small)
                        }
                    }
                    .foregroundStyle(isDangling ? Color.secondary : Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDangling)
                .help("Show this artifact on the Artifacts tab")

                if let recorded = source.nameAsRecorded?.trimmedNonEmpty {
                    HStack(spacing: 8) {
                        Text("as recorded: \(recorded)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Offered only when this recorded name isn't already one of the
                        // person's names — a document's own spelling of them (a Yiddish
                        // form, a married name) captured as a name, human-reviewed.
                        if let onAddName {
                            Button("Add as name", action: onAddName)
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .help("Add this recorded name to the person")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Unlink", action: onUnlink)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Remove the link to this artifact (⌘Z to undo)")
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }
}

/// Placeholder shown in the People detail pane when nothing is selected.
struct PersonDetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Person", systemImage: "person.crop.square",
            description: Text("Choose a person to see their names and facts."))
    }
}
