import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// One person-mention row: the recorded name + role, plus its resolution state — a
/// **Resolve…** button when unresolved, or a tappable chip (→ concluded person) with an
/// **Unlink** control when resolved. The trailing trash removes the *mention* (evidence),
/// which is distinct from Unlink (removes only the conclusion link). Mirrors
/// `AssertionRow`'s hover/focus-reveal trash chrome.
struct PersonMentionRow: View {
    @Environment(ArchiveModel.self) private var model
    let artifactID: ArtifactID
    /// The mention's position in the loaded record: the hint its remove starts from.
    let index: Int
    let mention: PersonMention
    /// The whole record's edges and mentions, so the row can name the other end of
    /// each relationship this mention takes part in.
    let statedRelationships: [MentionRelationship]
    let allMentions: [PersonMention]
    let link: EvidenceLink?
    /// The concluded person `link` points at, or `nil` — unlinked, or linked to a person
    /// that no longer exists.
    let resolvedPerson: PersonSummary?
    @Binding var sheet: ArtifactSheet?

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                header
                MentionRecordedFacts(
                    artifactID: artifactID, mention: mention, subject: subject, sheet: $sheet)
            }
            Spacer(minLength: 0)
            RowRemoveButton(
                isHovering: isHovering,
                accessibilityLabel: ArchiveCommand.removeMention.title,
                help: ArchiveCommand.removeMention.help(on: subject) ?? "",
                action: { model.perform(.removeMention, on: subject) })
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }

    /// What the row's commands act on (slice 83b).
    private var subject: CommandSubject {
        let state: MentionTarget.Link =
            if let link {
                resolvedPerson == nil
                    ? .stale(link.uid) : .linked(link.uid, to: link.personUid)
            } else {
                .none
            }
        return .mention(
            MentionTarget(
                artifact: artifactID, mention: mention, index: index, link: state,
                namesOthers: allMentions.count > 1))
    }

    /// The name, what the record states, and the resolution: the part of the row that is
    /// about the mention, so it carries the mention's context menu. The recorded facts
    /// below are rows of their own, and a right-click on one shouldn't offer to remove
    /// the mention.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The name + role/quality/age subtitle tap to edit the mention (the same
            // tap-to-edit affordance the People-tab name/fact rows use). The resolution
            // control below has its own actions and stays outside this button.
            Button {
                model.perform(.editMention, on: subject)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mention.nameAsRecorded)
                        .fontWeight(.medium)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit")
            StatedRelationshipsLine(
                localRef: mention.localRef, statedRelationships: statedRelationships,
                allMentions: allMentions)
            MentionResolutionControl(link: link, resolvedPerson: resolvedPerson, subject: subject)
        }
        .contentShape(Rectangle())
        .rowCommandMenu(subject)
    }

    /// "Subject · primary · age 45 · ru/Cyrl" — role always shown; quality omitted when
    /// undetermined (the default, so it's noise); age and the name's language/script only
    /// when present.
    private var subtitle: String? {
        var parts = [mention.role.displayName]
        if mention.informationQuality != .undetermined {
            parts.append(mention.informationQuality.displayName.lowercased())
        }
        if let age = mention.attributes?["ageAsRecorded"], !age.trimmed.isEmpty {
            parts.append("age \(age)")
        }
        if let tag = languageScriptTag(language: mention.nameLanguage, script: mention.nameScript) {
            parts.append(tag)
        }
        return parts.joined(separator: " · ")
    }
}

/// What the record states about how **this** person relates to the others it names
/// (slice 45k) — "Parent: Marcus Feldberg", read from this mention's vantage point.
///
/// A caption rather than a row list: the edges are edited in the mention sheet (the
/// same tap-to-edit this row already offers), and a second set of controls here
/// would give one statement two owners. Absent when the record states nothing about
/// this person, which is the common case.
private struct StatedRelationshipsLine: View {
    /// The mention whose vantage point the edges are read from.
    let localRef: String
    let statedRelationships: [MentionRelationship]
    let allMentions: [PersonMention]

    var body: some View {
        let mine = statedRelationships.filter { $0.involves(localRef) }
        if !mine.isEmpty {
            Text(mine.map(phrase(for:)).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One edge as this row reads it — phrased by `MentionRelationship+Display`, the single
    /// owner, so this row and the mention editor cannot describe one statement two ways.
    private func phrase(for edge: MentionRelationship) -> String {
        edge.phrase(from: localRef) { ref in
            allMentions.first { $0.localRef == ref }?.nameAsRecorded
        }
    }
}

/// The mention's resolution state: **Resolve…** when unlinked; a chip to the concluded
/// person, with **Why?** and **Unlink**, when linked; and a "Missing person" state with
/// **Re-resolve…** when the link points at a person that no longer exists (§2.3, no
/// cascade). The verbs are the row's commands (slice 83b), which read the same state.
private struct MentionResolutionControl: View {
    @Environment(ArchiveModel.self) private var model
    let link: EvidenceLink?
    let resolvedPerson: PersonSummary?
    let subject: CommandSubject

    /// Whether the link's **stored** match reasoning is expanded (slice 45e).
    @State private var isShowingReasoning = false

    var body: some View {
        if let link, resolvedPerson == nil {
            HStack(spacing: 8) {
                // Not a button: there is nothing to navigate to, and rendering it as one
                // is the bug — it looked live and then selected nothing.
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.small)
                    Text("Missing person")
                }
                .font(.caption)
                .padding(.vertical, 3)
                .padding(.horizontal, 9)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .help("This mention is linked to a person that was deleted")

                // A re-resolve replaces the stale link rather than adding a second one: the
                // subject's link state is what both the title and the payload read.
                RowCommandButton(.resolveMention, on: subject)
                RowCommandButton(.unlinkMention, on: subject, emphasis: .secondary)
            }
        } else if let link {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        model.perform(.showMentionedPerson, on: subject)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right")
                                .imageScale(.small)
                            Text(chipText)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 9)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(ArchiveCommand.showMentionedPerson.help(on: subject) ?? "")

                    Button(isShowingReasoning ? "Hide Reasoning" : "Why?") {
                        isShowingReasoning.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("The match reasoning stored on this link")

                    RowCommandButton(.unlinkMention, on: subject, emphasis: .secondary)
                }
                if isShowingReasoning {
                    StoredReasoning(link: link)
                }
            }
        } else {
            RowCommandButton(.resolveMention, on: subject, showsSymbol: true)
        }
    }

    /// The chip text: the concluded person's display name, plus its primary date
    /// (EDTF-glossed) when present. Only reached for a link that resolves — a dangling
    /// one renders the missing-person state instead — so a nameless person here exists
    /// and reads "Unnamed person", matching the relationship rows.
    private var chipText: String {
        let name = resolvedPerson?.displayName ?? "Unnamed person"
        if let date = resolvedPerson?.primaryDate, let edtf = EDTFDate.parse(date) {
            return "\(name) · \(edtf.humanDescription)"
        }
        return name
    }
}

/// The **stored** match reasoning for a resolved mention — the breakdown as it was
/// written, not as the matcher would score the pair today (slice 45e).
///
/// This is what makes the triage pane's promise checkable. Confirming a suggestion
/// stores the matcher's real dimension scores rather than rounding them up to 100
/// (45c), and without a surface like this the app asserted that and then never showed
/// it again — `genea match explain` was the only way to read a stored verdict.
///
/// **Deliberately not re-scored.** A breakdown is a verdict at a time: the archive has
/// changed since — a spouse relationship added, a name corrected — and re-deriving
/// these numbers on every render would quietly answer a different question than the one
/// the reviewer was asked. `matchScore(of:against:)` is the "what would it say now?"
/// path, and comparing the two is an audit, not a display.
///
/// A hand-made `link()` carries the honest minimum (`name: exact/100`, everything else
/// unassessed), and that reads correctly here: `not assessed` on four rows is precisely
/// the claim that no matcher ran.
private struct StoredReasoning: View {
    let link: EvidenceLink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.verdictLine(link))
                .font(.caption2)
                .foregroundStyle(.secondary)
                // Wraps rather than truncating: the tail is where `matcher-proposed` lives,
                // which is the whole distinction this line exists to draw.
                .fixedSize(horizontal: false, vertical: true)
            MatchBreakdownView(breakdown: link.match)
            SourceWeightsRow(
                sourceAuthority: link.sourceAuthorityWeight,
                informationQuality: link.informationQualityWeight)
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Layout.rowCornerRadius))
        .padding(.top, 2)
    }

    /// "Confidence 91 · human-confirmed · by the matcher · 30 July 2026" — who decided, how
    /// sure the matcher was, and when. The CLI's `verdictLine` in the app's register.
    ///
    /// `provenance.createdBy` is the interesting half: it separates a link a **matcher
    /// proposed and a human accepted** from one a human made unaided, which is exactly the
    /// distinction the mixed record 45c writes exists to preserve.
    private static func verdictLine(_ link: EvidenceLink) -> String {
        var parts = ["Confidence \(link.aggregateConfidence)"]
        parts.append(link.reviewStatus.rawValue.replacingOccurrences(of: "-", with: " "))
        parts.append(
            link.provenance.createdBy == .machine ? "matcher-proposed" : "recorded by hand")
        if let reviewer = link.reviewedBy?.trimmedNonEmpty {
            parts.append("by \(reviewer)")
        }
        // The machine timestamp is ISO 8601 (never EDTF — that is for event dates), so the
        // date part alone is the readable half.
        if let at = link.reviewedAt?.trimmedNonEmpty {
            parts.append(String(at.prefix(10)))
        }
        return parts.joined(separator: " · ")
    }
}

/// This mention's recorded facts (what the document states about this person),
/// each tap-to-edit + remove, with an always-present **Add Fact…** affordance.
/// Indented under the mention's name so it reads as belonging to it.
private struct MentionRecordedFacts: View {
    @Environment(ArchiveModel.self) private var model
    let artifactID: ArtifactID
    let mention: PersonMention
    /// The mention, for its Add Fact… and Add Relationship… (slice 83b).
    let subject: CommandSubject
    @Binding var sheet: ArtifactSheet?

    @FocusState private var focusedFact: AnyHashable?
    /// Focus owed to a fact whose editor replaced it (79b).
    @State private var focusReturn: RowFocusReturn?

    var body: some View {
        let rows = mention.facts.keyedRows()
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                AssertionRow(
                    title: row.element.type.displayName,
                    subtitle: Self.factSubtitle(row.element),
                    icon: "doc.text",
                    onEdit: { editFact(row) },
                    editFocus: RowFocus(state: $focusedFact, id: row.id)
                ) { deleteFact(row.element, near: row.index) }
            }
            HStack(spacing: 12) {
                RowCommandButton(.addMentionFact, on: subject, showsSymbol: true)
                // Slice 45k's editing lives in the mention sheet, and until this button
                // existed the only way to reach it was to know that clicking the name
                // opened it. The affordance names the feature; the sheet is still its one
                // owner (an edge belongs to the record, not to either end, so editing it
                // from two places would give one statement two owners). Not offered when
                // the record names nobody else — there is then no one to relate this
                // person to.
                RowCommandButton(.addMentionRelationship, on: subject, showsSymbol: true)
            }
        }
        .padding(.top, 2)
        .returnsRowFocus($focusReturn, rowIDs: rows.map { AnyHashable($0.id) }, focus: $focusedFact)
    }

    /// Opens the fact editor on `row`, as Add Fact… does. When the row has keyboard focus,
    /// focus comes back to it once the editor's change lands (79b).
    private func editFact(_ row: KeyedRow<RecordedFact, RecordedFact>) {
        let report = RowFocusReturn.request(
            for: row, focused: focusedFact, in: $focusReturn, key: { $0 })
        var request = ArtifactSheet(
            .mentionFact(
                mentionRef: mention.localRef, mentionName: mention.nameAsRecorded,
                mode: .edit(index: row.index, existing: row.element), report: report))
        if report != nil {
            request.onDismiss = { [$focusReturn] in RowFocusReturn.sheetClosed($focusReturn) }
        }
        sheet = request
    }

    /// Removes `fact` from this mention (undoable). The mention is found by its stable
    /// `localRef`, and the fact by value starting at the row's index, in the record the
    /// write reads. See `PersonMentionRow.deleteMention` on addressing.
    private func deleteFact(_ fact: RecordedFact, near index: Int) {
        let ref = mention.localRef
        model.updateMetadata(of: artifactID, actionName: "Remove Recorded Fact") { record in
            guard
                let mention = record.personsMentioned.firstIndex(where: { $0.localRef == ref }),
                let position = record.personsMentioned[mention].facts.position(
                    of: fact, near: index)
            else { return }
            record.personsMentioned[mention].facts.remove(at: position)
        }
    }

    /// "“tailor” · 1892 · Łomża · secondary" — value (quoted), date (EDTF-glossed) and
    /// place omitted when absent; the information quality is shown only when the fact
    /// **overrides** the mention's (i.e. it states its own), since an inherited quality
    /// is already implied by the row.
    private static func factSubtitle(_ fact: RecordedFact) -> String? {
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
        if let quality = fact.informationQuality {
            parts.append(quality.displayName.lowercased())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
