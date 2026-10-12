import GeneaLogicModel

/// Assembling a person's promotable evidence — the **one** implementation of what a
/// suggested fact is and when it has already been recorded (slices 42c/44i, hoisted out of
/// `PersonDetailView` in 45i).
///
/// It moved here because a second reader arrived: the Review section's cross-person lane.
/// Two readers of the same question is exactly where they drift, and the drift would be
/// invisible — a lane that offered a fact the person pane considered already recorded
/// would be worse than no lane at all, because the disagreement is silent and the user has
/// no way to tell which surface is right. So the dedupe rule, the id scheme, and the
/// couple-facts half of the comparison live in one place and both callers pass their
/// already-loaded records in.
///
/// Deliberately **pure** — no `Archive`, no `ArchiveModel`, no view state. The caller
/// supplies the links, the records they cite, and the facts to dedupe against; the two
/// closures let the cross-person sweep memoize artifact decodes across the whole pass
/// while the person pane keeps its per-person cache.
enum SuggestedFacts {

    /// The facts a suggestion must be deduped against: the person's own, **plus their
    /// couple facts**.
    ///
    /// The second half is the one that's easy to drop. A marriage or divorce promoted from
    /// evidence is stored on the couple `Relationship` (slice 43c), not in `Person.facts`,
    /// so a comparison against `person.facts` alone re-offers a marriage the user already
    /// recorded — every time they open the person.
    static func recordedFacts(of person: Person?, relationships: [Relationship]) -> [PersonFact] {
        (person?.facts ?? [])
            + relationships
            .filter { $0.type == .couple }
            .flatMap(\.facts)
    }

    /// Assembles the Sources rows **and** the Suggested-Facts rows in one pass over a
    /// person's evidence links — both read each linked artifact's full record, so they
    /// share the load.
    ///
    /// Suggestions are **mention-scoped** (slice 44i): each comes from the *resolved
    /// mention's* own `facts[]` (what this document records about *this* person, §10.6) —
    /// plus the mention's recorded age — so a suggestion is precisely "what this record
    /// states about this person", not a heuristic guess drawn from unscoped document-level
    /// events (a census lists many people). A link whose artifact was deleted (§2.3, no
    /// cascade) still yields a Source row ("Unknown artifact") but no suggestions.
    ///
    /// A suggestion the person has **already recorded** is dropped, so applying one removes
    /// it from the list; deleting that fact (⌘Z) brings the suggestion back on the next
    /// reload. An *edited* apply (the value was corrected before saving) no longer matches
    /// and stays — the evidence wasn't recorded as-is.
    ///
    /// - Parameters:
    ///   - links: the person's evidence links, rejections already excluded (45c).
    ///   - recordedFacts: what to dedupe against — see `recordedFacts(of:relationships:)`.
    ///   - artifactTitle: display title for a citing artifact, `nil` if it's gone.
    ///   - artifactRecord: the citing artifact's full record, `nil` if it's gone.
    static func assemble(
        links: [EvidenceLink],
        recordedFacts: [PersonFact],
        artifactTitle: (ArtifactID) -> String?,
        artifactRecord: (ArtifactID) -> Artifact?
    ) -> (sources: [PersonSource], suggestions: [FactSuggestion]) {
        var sources: [PersonSource] = []
        var suggestions: [FactSuggestion] = []

        func offer(_ suggestion: FactSuggestion) {
            guard !isAlreadyRecorded(suggestion, in: recordedFacts) else { return }
            suggestions.append(suggestion)
        }

        for link in links {
            let title = artifactTitle(link.artifactUid)
            let record = artifactRecord(link.artifactUid)
            let mention = record?.personsMentioned.first { $0.localRef == link.personMentionRef }

            sources.append(
                PersonSource(
                    linkID: link.uid,
                    artifactID: link.artifactUid,
                    artifactTitle: title,
                    nameAsRecorded: mention?.nameAsRecorded))

            // Each of the mention's recorded facts is scoped to *this* person — the whole
            // point of §10.6. A dangling link (no mention for the ref) contributes none.
            guard let mention else { continue }
            for (index, fact) in mention.facts.enumerated() {
                offer(
                    FactSuggestion(
                        id: "\(link.uid.raw)#rf\(index)",
                        link: link.uid, artifactID: link.artifactUid, artifactTitle: title,
                        evidence: .recordedFact(fact)))
            }
            // A recorded age is this mention's own evidence too — one per link.
            if let age = mention.attributes?["ageAsRecorded"]?.trimmedNonEmpty {
                offer(
                    FactSuggestion(
                        id: "\(link.uid.raw)#age",
                        link: link.uid, artifactID: link.artifactUid, artifactTitle: title,
                        evidence: .recordedAge(age)))
            }
        }
        return (sources, suggestions)
    }

    /// Whether `suggestion` has already been recorded as a fact.
    ///
    /// **The comparison has to match what the suggestion's path can actually produce**, and
    /// the two kinds of evidence differ there:
    ///
    /// - A **recorded fact** can be affirmed verbatim, so it is compared verbatim: same
    ///   link, type, date, place and value, with date/place normalized the way
    ///   `FactForm.build` does on save (shorthand → canonical EDTF, empty → `nil`) so an
    ///   un-edited apply matches exactly. An *edited* apply deliberately doesn't match and
    ///   the row stays — the evidence wasn't recorded as-is.
    /// - A **recorded age** can only ever be *transformed*: §2.3 forbids computing the year
    ///   for the user, so applying one means typing a derived date the evidence does not
    ///   state, and a verbatim comparison (which demands `date == nil`) can never be
    ///   satisfied by anything the editor is able to save. So the age is discharged by
    ///   *link + type*: a birth recorded from this source is the conclusion the age was
    ///   evidence for.
    ///
    /// Getting this wrong was invisible before 45i — a lingering row on one person's pane —
    /// and is not now: an inbox with a permanently undischargeable item is an inbox nobody
    /// finishes reading.
    ///
    /// Residual, and deliberate: if the human retypes the age into a *death* year (changing
    /// the type in the editor), the suggestion stays. No birth conclusion was drawn from
    /// this document, so the age is still un-promoted evidence for one — and a death fact
    /// citing the same source is as likely to have come from the record's own death entry,
    /// which is a separate suggestion with its own row.
    static func isAlreadyRecorded(_ suggestion: FactSuggestion, in facts: [PersonFact]) -> Bool {
        let type = suggestion.suggestedType
        if case .recordedAge = suggestion.evidence {
            return facts.contains {
                $0.supportedByLinks.contains(suggestion.link) && $0.type == type
            }
        }
        let date = suggestion.prefillDate?.trimmedNonEmpty.map(EDTFDate.normalizingShorthand)
        let place = suggestion.prefillPlace?.trimmedNonEmpty
        let value = suggestion.prefillValue?.trimmedNonEmpty
        return facts.contains { fact in
            fact.supportedByLinks.contains(suggestion.link)
                && fact.type == type
                && fact.date == date
                && fact.place == place
                && fact.value == value
        }
    }
}

/// A resolved evidence link seen from the person's side — one row of their **Sources**
/// section (slice 42b): which artifact cites them, under what recorded name, and the link
/// that ties the two. Assembled beside the suggestions because both read the same records.
///
/// `artifactTitle`/`nameAsRecorded` are `nil` when the citing artifact (or the mention
/// within it) is gone — a dangling link (§2.3), still shown so it stays visible and
/// unlinkable.
struct PersonSource: Identifiable {
    let linkID: EvidenceLinkID
    let artifactID: ArtifactID
    let artifactTitle: String?
    let nameAsRecorded: String?
    var id: EvidenceLinkID { linkID }
}
