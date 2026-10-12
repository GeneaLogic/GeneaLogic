import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Adds or edits one `PersonMention` on an artifact — a person the document *names*,
/// recorded exactly as written, plus their role and (slice 44h) the name's language and
/// script. This is **evidence** (who the record names), never a tree identity: resolving
/// a mention to a concluded `Person` and asserting relationships are conclusion-layer acts
/// handled elsewhere (the Resolve… chip, the People tab).
///
/// The People-tab analog is `PersonEditorSheet` (a concluded person's names); keeping
/// mention editing here and concluded-name editing there mirrors the two layers and keeps
/// each sheet single-purpose. A mention's recorded facts are edited in
/// `RecordedFactEditorSheet`, so this sheet writes only the mention's *own* fields and
/// leaves `facts` (and the record-local `localRef`) untouched.
///
/// Every commit writes through `ArchiveModel.updateMetadata`, so add/edit are **undoable**
/// (⌘Z). On add the `localRef` is minted at write time (never user-entered) via the
/// shared `PersonMention.nextLocalRef` rule, skipping any ref a surviving `EvidenceLink`
/// still claims (slice 44c).
struct PersonMentionEditorSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let artifactID: ArtifactID
    let mode: Mode

    /// Every mention on the record, including this one — the other ends a stated
    /// relationship can name (slice 45k). A record's edges point only within itself.
    let mentions: [PersonMention]

    /// The record's stated relationships as they were when the sheet opened. Only the
    /// ones touching this mention are shown or written; see ``save()`` for why the
    /// commit is a diff rather than a whole-array replace.
    let statedRelationships: [MentionRelationship]

    /// Add a new mention, or edit the one addressed by its stable `localRef`.
    enum Mode {
        case add
        case edit(ref: String, existing: PersonMention)
    }

    @State private var name: String
    @State private var role: PersonRole
    @State private var quality: InformationQuality
    /// Optional "age as recorded" — the canonical freeform attribute, stored under
    /// `attributes["ageAsRecorded"]`.
    @State private var age: String
    @State private var nameLanguage: String
    @State private var nameScript: String

    /// The relationships **touching this mention**, edited locally and committed on
    /// Save, so Cancel means what it says. Edges between two *other* mentions are not
    /// shown and never rewritten.
    @State private var edges: [MentionRelationship]

    /// The pending "state a relationship" row: how the other mention stands to this
    /// one, and which mention that is.
    @State private var newRelation: RelationKind = .parent
    @State private var newOtherRef: String?

    init(
        artifactID: ArtifactID, mode: Mode, mentions: [PersonMention] = [],
        statedRelationships: [MentionRelationship] = []
    ) {
        self.artifactID = artifactID
        self.mode = mode
        self.mentions = mentions
        self.statedRelationships = statedRelationships
        let ref: String? = if case .edit(let ref, _) = mode { ref } else { nil }
        _edges = State(
            initialValue: ref.map { me in statedRelationships.filter { $0.involves(me) } } ?? [])
        // Only a seed; `resolvedOtherRef` is what the picker and the State button read,
        // so a default that later becomes unofferable (it got related, or the record
        // changed) can never leave the picker showing a selection that isn't in it.
        _newOtherRef = State(initialValue: mentions.first { $0.localRef != ref }?.localRef)
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _role = State(initialValue: .subject)
            _quality = State(initialValue: .undetermined)
            _age = State(initialValue: "")
            _nameLanguage = State(initialValue: "")
            _nameScript = State(initialValue: "")
        case .edit(_, let mention):
            _name = State(initialValue: mention.nameAsRecorded)
            _role = State(initialValue: mention.role)
            _quality = State(initialValue: mention.informationQuality)
            _age = State(initialValue: mention.attributes?["ageAsRecorded"] ?? "")
            _nameLanguage = State(initialValue: mention.nameLanguage ?? "")
            _nameScript = State(initialValue: mention.nameScript ?? "")
        }
    }

    /// Stands in for **this mention's own `localRef` while it doesn't have one yet** —
    /// an add mints its ref at write time and never before (`nextLocalRef`'s rule), so an
    /// edge staged in the Add sheet has nothing real to name its near end.
    ///
    /// Safe as a placeholder precisely because it is not a ref: every `localRef` is
    /// `p<n>`, so no stored edge can name the empty string, and `save()` rebinds it to
    /// the minted ref inside the same write. Nothing carrying it ever reaches disk.
    /// `nonisolated` so the off-main `Edits` snapshot can rebind against it.
    private nonisolated static let pendingSelfRef = ""

    /// This mention's ref as the sheet knows it: the record's on an edit, the
    /// placeholder on an add.
    private var selfRef: String { editingRef ?? Self.pendingSelfRef }

    /// How the *other* mention stands to the one being edited — the same perspective
    /// vocabulary `RelationshipEditorSheet` uses one layer up, so the user never has to
    /// think in `person1Ref`/`person2Ref`. The §4.5 mapping lives in ``edge(to:)``.
    private enum RelationKind: String, CaseIterable, Identifiable {
        case parent, child, partner
        var id: String { rawValue }
        /// Lower-case because the picker now sits **inside a sentence** ("This person's
        /// parent is …") rather than labelling a field. Capitalized mid-clause it read as a
        /// heading that had wandered into the text.
        var label: String {
            switch self {
            case .parent: "parent"
            case .child: "child"
            case .partner: "partner"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            // The form scrolls; the header and the Cancel/Save footer do not. A sheet is
            // bounded by the window presenting it, and this one's height is no longer
            // fixed — the relationships section grows with the record — so on a small
            // window the fields ran off the top and bottom edges once a few were stated.
            // `.fitted` still sizes the sheet to its content, so an add (no relationships
            // section at all) opens exactly as compact as it did before; the scroll only
            // engages once the window can't give the sheet the height it asked for.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fields
                    Divider()
                    relationships
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A gutter for the overlay scroll bar, which is drawn *over* the content
                // and otherwise lands on the rows' trash buttons — the one place in this
                // sheet where a control reaches the trailing edge. Plain padding rather
                // than `.contentMargins(…, for: .scrollContent)`, which left the content
                // at the full width here and so moved nothing.
                .padding(.trailing, Layout.scrollIndicatorGutter)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .padding(Layout.sheetPadding)
        // Width-resizable, height fits the fields — matching the other form sheets (F5).
        // The height **floor** is the other half of the clipping fix: `.fitted` sizes a
        // sheet once at open and does not regrow, so a Relationships section that grows
        // as you state edges had nowhere to go. The floor reserves the common case's
        // room; the scroll view above covers everything past it.
        .presentationSizing(.fitted)
        .frame(
            minWidth: Layout.FormSheet.minWidth, idealWidth: Layout.FormSheet.idealWidth,
            maxWidth: Layout.FormSheet.maxWidth,
            minHeight: Layout.FormSheet.scrollingMinHeight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isEditing ? "Edit Person Mentioned" : "Add Person Mentioned")
                .font(.headline)
            Text(
                "A person this artifact names — the name exactly as written, plus their role. This is evidence (who the document names), not yet a tree identity."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("Name as Recorded") {
                TextField("Name", text: $name, prompt: Text("name exactly as written"))
                    .labelsHidden()
            }
            LabeledField("Role") {
                Picker("Role", selection: $role) {
                    ForEach(PersonRole.pickerOptions(including: anchorRole), id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledField("Information Quality") {
                Picker("Information Quality", selection: $quality) {
                    ForEach(InformationQuality.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledField("Age as Recorded") {
                TextField("Age", text: $age, prompt: Text("optional, e.g. 45")).labelsHidden()
            }
            // The name's own language/script — distinct from the document's language,
            // since one record routinely records names in several (slice 44h).
            LabeledField("Name Language") {
                TextField("Name Language", text: $nameLanguage, prompt: Text("BCP 47, e.g. ru"))
                    .labelsHidden()
            }
            LabeledField("Name Script") {
                TextField("Name Script", text: $nameScript, prompt: Text("ISO 15924, e.g. Cyrl"))
                    .labelsHidden()
            }
        }
    }

    /// **What this document says about who is whose** (slice 45k) — an evidence-layer
    /// statement, not a conclusion: relating two mentions asserts nothing about the
    /// people they may resolve to.
    ///
    /// Present on an **add** as well as an edit. The ref this mention will be known by
    /// doesn't exist yet, which is why edges staged here carry ``pendingSelfRef`` until
    /// `save()` rebinds them — but "who is this person to the others on the page?" is
    /// most of why you are adding the second and third mention at all, and sending the
    /// cataloguer back through a second sheet to say it is the wrong shape of work.
    @ViewBuilder
    private var relationships: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relationships This Record States")
                .font(.subheadline.weight(.semibold))
            Text(
                "What the document says about how the people it names are related — "
                    + "which parents belong to which spouse, and so on. This is what the "
                    + "record states, not a conclusion about the people themselves."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            // Answering the question this section otherwise invites — "must I restate
            // what the roles already say?" A record with one clear subject is already
            // read correctly from its roles; stating edges there is duplicate work, and
            // the section should say so rather than let a cataloguer discover it.
            Text(needsStatedRelationships ? whenToStateGuidance : rolesAlreadySayIt)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(edges.enumerated()), id: \.offset) { index, edge in
                HStack(spacing: 6) {
                    Text(phrase(for: edge))
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button {
                        edges.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove this stated relationship")
                    .accessibilityLabel("Remove Stated Relationship")
                }
            }

            if let unavailable = noOneToRelateTo {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // **A sentence, not a labelled pair.** It read `[Parent ▾] of this person:
                // [Name ▾]`, where the colon left "Parent of this person" free to attach
                // either way — a cataloguer could reasonably take it as *this* person being
                // the named one's parent, which is the opposite edge. Hand-testing found it.
                // Written out with the possessive first, the direction is in the grammar and
                // there is nothing left to infer.
                // **The name picker is the only part that gives.** Everything else here is
                // fixed vocabulary — three relations, two words of connective tissue — while
                // the name is arbitrary user text, so it is the one control that can be
                // asked to truncate. With `.fixedSize()` on all of them the sentence broke
                // across lines at the sheet's minimum width instead, which is the one thing
                // a sentence must not do when its whole job is to read in order.
                HStack(spacing: 6) {
                    Text("This person’s")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Picker("Relation", selection: $newRelation) {
                        ForEach(RelationKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("is")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Picker("Other Mention", selection: otherRefSelection) {
                        ForEach(relatableMentions, id: \.localRef) {
                            Text($0.nameAsRecorded).tag(String?.some($0.localRef))
                        }
                    }
                    .labelsHidden()
                    Button("State") { stateRelationship() }
                        .disabled(pendingEdge == nil)
                        .fixedSize()
                }
            }
        }
    }

    /// The people this mention can still be related **to**: everyone else the record
    /// names, minus anyone it is already related to.
    ///
    /// Dropping the already-related is what keeps the menu honest. Leaving them in
    /// offered a choice whose only outcome was a disabled State button — and worse, it
    /// implied a second Sidney↔Gussie relationship was a thing to add, when what the
    /// user actually wants there is to *change* the one that exists. Removing the row
    /// above puts the person straight back in this menu, so change is delete-then-state
    /// and there is exactly one way to end up with one edge.
    private var relatableMentions: [PersonMention] {
        mentions.filter { candidate in
            candidate.localRef != selfRef
                && !edges.contains { $0.involves(candidate.localRef) }
        }
    }

    /// Why the picker is absent, or `nil` when there is someone to offer. The two cases
    /// read very differently to a cataloguer — nobody here yet, versus everybody already
    /// accounted for — and a single "can't do that" line would be wrong for both.
    private var noOneToRelateTo: String? {
        if !relatableMentions.isEmpty { return nil }
        if mentions.contains(where: { $0.localRef != selfRef }) {
            return "Everyone else this record names already has a stated relationship "
                + "with this person. Remove one above to change it."
        }
        return "Record another person on this document to state a relationship between them."
    }

    /// The picker's selection, resolved against what is actually offered: the seeded
    /// choice may have just been related (and so left the menu). A `Picker` whose
    /// selection isn't among its tags renders blank and silently refuses to commit, so
    /// the fallback is load-bearing, not defensive.
    private var otherRefSelection: Binding<String?> {
        Binding(
            get: { resolvedOtherRef },
            set: { newOtherRef = $0 })
    }

    private var resolvedOtherRef: String? {
        if let newOtherRef, relatableMentions.contains(where: { $0.localRef == newOtherRef }) {
            return newOtherRef
        }
        return relatableMentions.first?.localRef
    }

    /// Whether this record actually **needs** its edges stated — the same question the
    /// matcher asks, kept in the same terms (`Matcher`'s star rule, §6.1).
    ///
    /// A record with exactly one `subject` has an unambiguous centre: every other role is
    /// read relative to it, and both the matcher and the suggested-relationship
    /// derivation get it right from the roles alone. A record with none — or with two
    /// `spouse`s and four `parent`s — is the shape where "whose parent?" has no answer
    /// until somebody says.
    /// The **live** role is what counts, not the stored one: this sheet may be adding the
    /// second `subject` — the very change that turns an unambiguous record into one that
    /// needs its edges stated — and guidance computed from the record as it was would
    /// tell the user the opposite of what they are in the middle of doing.
    private var needsStatedRelationships: Bool {
        var roles = mentions.filter { $0.localRef != selfRef }.map(\.role)
        roles.append(role)
        return roles.filter { $0 == .subject }.count != 1
    }

    private var whenToStateGuidance: String {
        "This record has no single subject, so which person a parent or partner belongs "
            + "to isn’t implied by their roles. Stating it here is what makes the "
            + "difference."
    }

    private var rolesAlreadySayIt: String {
        "Optional here: this record has one subject, so the other roles are already read "
            + "as relative to them. State a relationship only where the roles leave it "
            + "genuinely unclear."
    }

    /// The `localRef` being edited, or `nil` on an add (where none exists yet).
    private var editingRef: String? {
        if case .edit(let ref, _) = mode { return ref }
        return nil
    }

    /// The edge the pickers currently describe, or `nil` when it can't be stated —
    /// no other mention selected, or the record already says it (one edge is one entry).
    private var pendingEdge: MentionRelationship? {
        let me = selfRef
        guard let other = resolvedOtherRef, other != me,
            let edge = edge(to: other, as: newRelation, from: me),
            // Not `contains(edge)`: a `couple` written from the other end is the same
            // statement, and offering to state it again would store it twice (§6.1).
            !edges.contains(where: { $0.statesSameRelationship(as: edge) })
        else { return nil }
        return edge
    }

    /// Maps the perspective choice onto the stored pair (§4.5: `person1Ref` is the
    /// parent; a `couple` is symmetric) — the one place in the app that decides the
    /// direction of an evidence-layer edge.
    private func edge(to other: String, as kind: RelationKind, from me: String)
        -> MentionRelationship?
    {
        switch kind {
        case .parent:
            MentionRelationship(type: .parentChild, person1Ref: other, person2Ref: me)
        case .child:
            MentionRelationship(type: .parentChild, person1Ref: me, person2Ref: other)
        case .partner:
            MentionRelationship(type: .couple, person1Ref: other, person2Ref: me)
        }
    }

    private func stateRelationship() {
        guard let edge = pendingEdge else { return }
        edges.append(edge)
    }

    /// "Parent: Marcus Feldberg" — the edge read from *this* mention's vantage point,
    /// which is the only reading that makes sense in a sheet about one person. An edge
    /// of an unrecognized type is described by its own raw value rather than being
    /// hidden: the record says it, so the editor shows it (and can remove it).
    private func phrase(for edge: MentionRelationship) -> String {
        edge.phrase(from: selfRef) { ref in
            mentions.first { $0.localRef == ref }?.nameAsRecorded
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save" : "Add to Artifact") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmed.isEmpty)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The role picker is anchored on the record's **original** role, not the live
    /// selection, so a role authored elsewhere (an off-list `.unknown(...)`, possible
    /// since `PersonRole` opened in slice 44h) stays offered. For an add the anchor is
    /// the default known case.
    private var anchorRole: PersonRole {
        if case .edit(_, let mention) = mode { return mention.role }
        return .subject
    }

    private func save() {
        guard !name.trimmed.isEmpty else { return }
        let edits = snapshotEdits()
        switch mode {
        case .add:
            // Links are read *before* the mutation so the mint can skip any ref a
            // surviving `EvidenceLink` still claims (`nextLocalRef`'s rule) — including
            // rejection tombstones, which claim a ref exactly as firmly.
            let existingLinks = model.refClaimingLinks(for: artifactID)
            model.updateMetadata(of: artifactID, actionName: "Add Person Mentioned") { record in
                // Minted here and nowhere else, which is why any relationship staged in
                // this sheet is rebound *inside the same write*: the ref the edges name
                // comes into existence on this line.
                let ref = PersonMention.nextLocalRef(
                    in: record.personsMentioned, claimedBy: existingLinks,
                    statedIn: record.mentionRelationships)
                record.personsMentioned.append(
                    PersonMention(
                        localRef: ref,
                        nameAsRecorded: edits.name,
                        role: edits.role,
                        informationQuality: edits.quality,
                        nameLanguage: edits.nameLanguage,
                        nameScript: edits.nameScript,
                        attributes: edits.mergedAttributes(nil)))
                edits.applyRelationshipEdits(to: &record, knownAs: ref)
            }
        case .edit(let ref, _):
            model.updateMetadata(of: artifactID, actionName: "Edit Person Mentioned") { record in
                guard
                    let position = record.personsMentioned.firstIndex(where: {
                        $0.localRef == ref
                    })
                else { return }
                // Assign the fields this sheet **owns**, leaving `facts` and `localRef`
                // untouched (the owned-field discipline — a whole-value replace would
                // silently drop the recorded facts and re-home every evidence link).
                record.personsMentioned[position].nameAsRecorded = edits.name
                record.personsMentioned[position].role = edits.role
                record.personsMentioned[position].informationQuality = edits.quality
                record.personsMentioned[position].nameLanguage = edits.nameLanguage
                record.personsMentioned[position].nameScript = edits.nameScript
                record.personsMentioned[position].attributes = edits.mergedAttributes(
                    record.personsMentioned[position].attributes)
                edits.applyRelationshipEdits(to: &record, knownAs: ref)
            }
        }
        dismiss()
    }

    /// Everything `save()` is about to write, read off `@State` **here on the main
    /// actor** — before the closure that writes it leaves for the background.
    ///
    /// `updateMetadata`'s `edit` closure is `@escaping @Sendable` and runs inside
    /// `mutate`'s off-main work block (52). Reading the sheet's `@State` from in there is
    /// a real cross-actor read of values the user can still be typing into; the pre-53
    /// build settings simply weren't checking for it. Snapshotting *removes* the read,
    /// which annotating the capture away would not have (slice 53 fork (b)).
    private func snapshotEdits() -> Edits {
        Edits(
            name: name.trimmed,
            role: role,
            quality: quality,
            nameLanguage: nameLanguage.trimmedNonEmpty,
            nameScript: nameScript.trimmedNonEmpty,
            age: age.trimmedNonEmpty,
            edges: edges,
            // The removal diff is computed here rather than in the write closure for the
            // same reason: `statedRelationships` and `selfRef` are the view's.
            removedEdges: statedRelationships.filter { original in
                original.involves(selfRef) && !edges.contains(original)
            })
    }

    /// The snapshot itself: a plain value, so the write closure carries no reference
    /// back to the view. `nonisolated` because it is *used* off the main actor.
    private nonisolated struct Edits: Sendable {
        var name: String
        var role: PersonRole
        var quality: InformationQuality
        var nameLanguage: String?
        var nameScript: String?
        var age: String?
        var edges: [MentionRelationship]
        var removedEdges: [MentionRelationship]

        /// Commits the stated-relationship edits as a **diff**, not a whole-array replace.
        ///
        /// `mentionRelationships` is artifact-level while this sheet is about one mention:
        /// writing back the array it was opened with would silently revert any edge between
        /// two *other* mentions that changed meanwhile (an undo, or a second window). So
        /// only the exact edges the user removed are removed, and only the new ones appended
        /// — and an edge that is somehow already there is not duplicated, since one edge is
        /// one entry (§6.1).
        ///
        /// - Parameter ref: the `localRef` this mention is known by **on disk** — the
        ///   record's own on an edit, and on an add the one just minted. Staged edges name
        ///   this mention by ``pendingSelfRef`` until here, so this is where they become
        ///   real.
        func applyRelationshipEdits(to record: inout Artifact, knownAs ref: String) {
            record.mentionRelationships.removeAll { removedEdges.contains($0) }
            for staged in edges {
                let edge = staged.rebinding(PersonMentionEditorSheet.pendingSelfRef, to: ref)
                guard
                    !record.mentionRelationships.contains(where: {
                        $0.statesSameRelationship(as: edge)
                    })
                else { continue }
                record.mentionRelationships.append(edge)
            }
        }

        /// Sets or clears `ageAsRecorded` within the mention's existing attributes,
        /// dropping the whole dictionary when it ends up empty (an absent optional,
        /// not `[:]`).
        func mergedAttributes(_ existing: [String: String]?) -> [String: String]? {
            var attributes = existing ?? [:]
            if let age {
                attributes["ageAsRecorded"] = age
            } else {
                attributes.removeValue(forKey: "ageAsRecorded")
            }
            return attributes.isEmpty ? nil : attributes
        }
    }
}
