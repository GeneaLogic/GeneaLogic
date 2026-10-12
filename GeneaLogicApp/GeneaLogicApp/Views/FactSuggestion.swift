import GeneaLogicModel

/// A promotable piece of evidence from an artifact linked to a person — a **mention-
/// scoped `RecordedFact`** (what the document records about *this* person), or the
/// mention's recorded age — that the researcher can **confirm** into a `PersonFact`
/// (slice 42c). Deliberately *not* auto-copied (§2.3, the conclusion-layer analog of the
/// scan-date trap): evidence a document records about a person is not the same as a
/// concluded fact about them until a human derives + asserts it. So a suggestion only
/// *prefills* the fact editor — the human confirms the type and corrects the value before
/// anything is written, and the promoted fact cites the supporting `EvidenceLink` via
/// `supportedByLinks`.
///
/// Slice 44i moved the evidence source from the artifact's **document-level** `events[]`
/// (which aren't scoped to any one mentioned person — a census lists many) to the
/// resolved mention's own `facts[]`, so a suggestion is now precisely "what this record
/// states about this person" rather than a heuristic guess.
struct FactSuggestion: Identifiable {
    enum Evidence {
        /// A fact the linked artifact records **about this mention** (type/date/place).
        case recordedFact(RecordedFact)
        /// The mention's `ageAsRecorded` attribute.
        case recordedAge(String)
    }

    /// A **stable** identity (link uid + evidence discriminator), so `ForEach` diffs
    /// suggestion rows across a reload instead of re-creating them (a fresh per-load
    /// UUID would discard row state on every `mutationVersion` bump). The supplier
    /// guarantees uniqueness: a link contributes one age plus its artifact's events by
    /// index.
    let id: String
    /// The evidence link this suggestion — and any fact promoted from it — cites.
    let link: EvidenceLinkID
    /// The citing artifact this evidence comes from. Used to pre-suggest the spouse for
    /// a couple fact promoted from evidence (slice 43c): the *other* person linked on the
    /// same artifact defaults the "With" picker.
    let artifactID: ArtifactID
    /// The citing artifact's title, for display context (`nil` if unresolvable).
    let artifactTitle: String?
    let evidence: Evidence

    /// Whether this suggestion can be recorded **in one click**, un-edited (slice 44i).
    /// True only for a `.recordedFact` whose type is *not* a couple type: a couple fact
    /// (marriage/divorce) needs a spouse chosen, and a `.recordedAge` needs the human to
    /// derive a year from the age + the source's date — both require the editor sheet, so
    /// they offer only "Apply…". Everything else (a person fact, or a custom type) can be
    /// affirmed as-recorded directly.
    var isDirectlyRecordable: Bool {
        guard case .recordedFact = evidence else { return false }
        return !FactType.coupleCases.contains(suggestedType)
    }

    /// The fact type to preselect: the recorded fact's own type (folded case-insensitively
    /// to a known case, so a `.unknown("birth")` twin authored elsewhere doesn't surface
    /// as a duplicate picker entry — the 42c rule, via the shared
    /// `OpenVocabulary.parsingLeniently`), or `.birth` for a recorded age (an age most
    /// often derives a birth year). The human can change it.
    var suggestedType: FactType {
        switch evidence {
        case .recordedFact(let fact): return FactType.parsingLeniently(fact.type.rawValue)
        case .recordedAge: return .birth
        }
    }

    /// Prefill for the fact's date field. A recorded fact's date carries over verbatim; a
    /// recorded age prefills nothing — the human derives the year from the age plus the
    /// source's own date (never auto-computed, §2.3).
    var prefillDate: String? {
        switch evidence {
        case .recordedFact(let fact): return fact.date
        case .recordedAge: return nil
        }
    }

    /// Prefill for the fact's place field (a recorded fact's place; nothing for an age).
    var prefillPlace: String? {
        switch evidence {
        case .recordedFact(let fact): return fact.place
        case .recordedAge: return nil
        }
    }

    /// Prefill for the fact's value field — a recorded fact's value (occupation, physical
    /// description); nothing for an age.
    var prefillValue: String? {
        switch evidence {
        case .recordedFact(let fact): return fact.value
        case .recordedAge: return nil
        }
    }

    /// A one-line rendering of the raw evidence, for the suggestion row and the editor's
    /// "from evidence" context. Dates are EDTF-glossed like everywhere else.
    var evidenceLine: String {
        switch evidence {
        case .recordedFact(let fact):
            var parts = [fact.type.displayName]
            if let value = fact.value?.trimmedNonEmpty {
                parts.append("“\(value)”")
            }
            if let date = fact.date?.trimmedNonEmpty {
                parts.append(EDTFDate.parse(date)?.humanDescription ?? date)
            }
            if let place = fact.place?.trimmedNonEmpty {
                parts.append(place)
            }
            return parts.joined(separator: " · ")
        case .recordedAge(let age):
            return "Recorded age: \(age)"
        }
    }
}
