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
    /// The mention's position in the loaded record, which its remove addresses.
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
                // The name + role/quality/age subtitle tap to edit the mention (the same
                // tap-to-edit affordance the People-tab name/fact rows use). The
                // resolution control and recorded facts below have their own actions and
                // stay outside this button.
                Button {
                    sheet = ArtifactSheet(
                        .mention(.edit(ref: mention.localRef, existing: mention)))
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
                MentionResolutionControl(
                    mention: mention, link: link, resolvedPerson: resolvedPerson,
                    sheet: $sheet)
                MentionRecordedFacts(
                    artifactID: artifactID, mention: mention,
                    canRelate: allMentions.count > 1, sheet: $sheet)
            }
            Spacer(minLength: 0)
            RowRemoveButton(
                isHovering: isHovering,
                accessibilityLabel: "Remove Mention",
                help: "Remove this mention (⌘Z to undo)",
                action: deleteMention)
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Removes this mention (undoable). The index addresses the loaded record, which
    /// matches stored order; the bounds check guards against a stale index after a
    /// concurrent reload. Any `EvidenceLink` pointing at the removed `localRef` is left
    /// dangling — that's `verifyIntegrity()`'s job (§2.3).
    private func deleteMention() {
        model.updateMetadata(of: artifactID, actionName: "Remove Person Mentioned") {
            guard $0.personsMentioned.indices.contains(index) else { return }
            $0.personsMentioned.remove(at: index)
        }
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
/// cascade).
private struct MentionResolutionControl: View {
    @Environment(ArchiveModel.self) private var model
    let mention: PersonMention
    let link: EvidenceLink?
    let resolvedPerson: PersonSummary?
    @Binding var sheet: ArtifactSheet?

    /// Whether the link's **stored** match reasoning is expanded (slice 45e).
    @State private var isShowingReasoning = false

    var body: some View {
        if staleLink != nil {
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

                Button("Re-resolve…", action: resolve)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("Point this citation at a person that still exists")

                Button("Unlink", action: unlink)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Drop the stale link, leaving the mention unresolved (⌘Z to undo)")
            }
        } else if let link {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        model.navigateToPerson(link.personUid)
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
                    .help("Show this person in the People tab")

                    Button(isShowingReasoning ? "Hide Reasoning" : "Why?") {
                        isShowingReasoning.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("The match reasoning stored on this link")

                    Button("Unlink", action: unlink)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Remove the link to this person (⌘Z to undo)")
                }
                if isShowingReasoning {
                    StoredReasoning(link: link)
                }
            }
        } else {
            Button(action: resolve) {
                Label("Resolve…", systemImage: "link")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Link this mention to a concluded person")
        }
    }

    /// The link, when it points at a person that no longer exists. One predicate, used
    /// for both the rendering and the payload: if they could disagree, a "Re-resolve…"
    /// that passed `nil` would *add* a second link to the same mention rather than
    /// replacing the stale one (the engine's `link` has no one-per-localRef guard),
    /// leaving two wrong citations.
    private var staleLink: EvidenceLink? {
        resolvedPerson == nil ? link : nil
    }

    /// Opens the resolve sheet: a first resolve, or a re-resolve replacing `staleLink`.
    private func resolve() {
        sheet = ArtifactSheet(.resolve(mention: mention, replacing: staleLink?.uid))
    }

    private func unlink() {
        if let link { model.unlinkMention(link.uid) }
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
    /// Whether there is anyone on this record to relate this mention *to*.
    let canRelate: Bool
    @Binding var sheet: ArtifactSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(mention.facts.enumerated()), id: \.offset) { index, fact in
                AssertionRow(
                    title: fact.type.displayName,
                    subtitle: Self.factSubtitle(fact),
                    icon: "doc.text",
                    onEdit: { editFact(.edit(index: index, existing: fact)) }
                ) { deleteFact(index) }
            }
            HStack(spacing: 12) {
                Button {
                    editFact(.add)
                } label: {
                    Label("Add Fact…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Record what this document states about this person")

                // Slice 45k's editing lives in the mention sheet, and until this button
                // existed the only way to reach it was to know that clicking the name
                // opened it. The affordance names the feature; the sheet is still its one
                // owner (an edge belongs to the record, not to either end, so editing it
                // from two places would give one statement two owners). Hidden when the
                // record names nobody else — there is then no one to relate this person to.
                if canRelate {
                    Button {
                        sheet = ArtifactSheet(
                            .mention(.edit(ref: mention.localRef, existing: mention)))
                    } label: {
                        Label("Add Relationship…", systemImage: "person.2")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("State how this document relates this person to another it names")
                }
            }
        }
        .padding(.top, 2)
    }

    /// Opens the fact editor on this mention, addressed by its stable `localRef`; its
    /// name rides along for the editor's heading.
    private func editFact(_ mode: RecordedFactEditorSheet.Mode) {
        sheet = ArtifactSheet(
            .mentionFact(
                mentionRef: mention.localRef, mentionName: mention.nameAsRecorded, mode: mode))
    }

    /// Removes the recorded fact at `index` from this mention (undoable). The mention is
    /// found by its stable `localRef`; both bounds are checked inside the closure against
    /// the loaded record. See `PersonMentionRow.deleteMention` on indexing.
    private func deleteFact(_ index: Int) {
        let ref = mention.localRef
        model.updateMetadata(of: artifactID, actionName: "Remove Recorded Fact") { record in
            guard
                let position = record.personsMentioned.firstIndex(where: { $0.localRef == ref })
            else { return }
            guard record.personsMentioned[position].facts.indices.contains(index) else { return }
            record.personsMentioned[position].facts.remove(at: index)
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
