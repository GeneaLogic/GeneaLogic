import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// Shared rendering for the conclusions commands (`person show`, `relate`,
/// `fact`, …) — the CLI's equivalent of the app's display helpers.
///
/// **Two output registers, deliberately kept apart** (the `list`/`find` doc comment
/// states the first): the *list* commands print strict `<uid>\t<…>` lines with no
/// decoration so they pipe (`genea person list a.genea | cut -f1`); `show` is the
/// human-readable register, free to use sections, indices and EDTF glosses. Only
/// `show`-style output uses the multi-part helpers here.
enum ConclusionsFormat {

    // MARK: - Names

    /// `Person.displayName` (the shared model rule) with the CLI's placeholder for
    /// a person carrying no usable name.
    ///
    /// The *placeholder* is the only part that belongs here — it's presentation,
    /// and the consumers legitimately differ: `person show` says "(unnamed)" while
    /// `person list` prints an empty column, so `cut -f2` can't mistake decoration
    /// for a real name.
    static func displayNameOrPlaceholder(_ person: Person) -> String {
        person.displayName ?? "(unnamed)"
    }

    /// `"Анна Штернфельд (birth) [ru/Cyrl]"` — a name plus its type, and its
    /// language/script tags when it carries them, for `person show`.
    ///
    /// The tags are shown only when present: an untagged name must not read as
    /// though someone determined it was untagged, and without showing them at all a
    /// caller who sets `--language` gets no confirmation it landed.
    static func nameLine(_ name: PersonName) -> String {
        var line = "\(name.resolvedText ?? "(unnamed)") (\(name.type.rawValue))"
        if let tag = languageScriptTag(name.language, name.script) {
            line += " [\(tag)]"
        }
        return line
    }

    /// The two orthogonal name tags as one attribute — `"ru/Cyrl"`, or `"ru"` /
    /// `"Cyrl"` when only one is recorded — or `nil` when neither is.
    ///
    /// Shared by `nameLine` (conclusions) and `ArtifactFormat.mentionLine`
    /// (evidence), which are the same concept on two layers. They were written in one
    /// slice and had **already** drifted: one tested `!= nil`, the other tested
    /// non-empty, so a name carrying `language: ""` rendered `[/]` on one side and
    /// nothing on the other. Both also emitted a dangling separator (`ru/`) when only
    /// one tag was set. One definition, one answer: whitespace-only counts as absent
    /// (matching `PersonName.resolvedText`), and the separator appears only between
    /// two present values.
    static func languageScriptTag(_ language: String?, _ script: String?) -> String? {
        let parts = [language, script]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// How a person id renders inside a `show` listing: `"PER-… Anna Meyer"`, or
    /// `"PER-… (deleted person)"` when the id no longer resolves.
    ///
    /// A dangling endpoint is expected, not exceptional: removals deliberately
    /// don't cascade (§2.3), so a relationship or link can outlive the person it
    /// names. The app renders this as "Unknown person"; the CLI says "deleted
    /// person" and still prints the uid, so the stale record stays actionable
    /// (`genea unrelate` / `genea unlink` take it straight off this line).
    static func personLabel(_ id: PersonID, in archive: Archive) -> String {
        guard let person = archive.person(withID: id) else {
            return "\(id.raw) (deleted person)"
        }
        return "\(id.raw) \(displayNameOrPlaceholder(person))"
    }

    // MARK: - Dates & facts

    /// A stored EDTF value plus its human gloss when the two differ — e.g.
    /// `"1892~ (about 1892)"`, but plain `"1892"` for a value that gloss-renders
    /// as itself. An unparseable value (legitimate free text) prints verbatim.
    static func date(_ stored: String) -> String {
        guard let parsed = EDTFDate.parse(stored) else { return stored }
        let gloss = parsed.humanDescription
        return gloss == stored ? stored : "\(stored) (\(gloss))"
    }

    /// The `type`, `date`, `place` and `value` columns every fact renders, absent parts
    /// omitted rather than printed as empty columns.
    ///
    /// Shared by `factLine` (a concluded `PersonFact`) and
    /// `ArtifactFormat.recordedFactLine` (an evidence-layer `RecordedFact`). The two
    /// types are deliberately distinct — a `PersonFact` cites evidence, a
    /// `RecordedFact` *is* evidence — but they differ only in their **trailing**
    /// column, so the prefix is defined once here. That also makes structural the
    /// promise `ArtifactFormat`'s header already states: a date renders identically
    /// wherever it appears.
    static func factParts(
        type: FactType, date storedDate: String?, place: String?, value: String? = nil
    ) -> [String] {
        var parts = [type.rawValue]
        if let stored = storedDate, !stored.isEmpty { parts.append(date(stored)) }
        if let place, !place.isEmpty { parts.append(place) }
        // A value-bearing fact's value (an occupation, a physical description), marked
        // so it reads as the fact's value and not another place column (slice 44i).
        if let value, !value.isEmpty { parts.append("“\(value)”") }
        return parts
    }

    /// `"Birth  1892~ (about 1892)  Chicago, Illinois"` — type, date, place, value, with
    /// absent parts omitted rather than printed as empty columns.
    static func factLine(_ fact: PersonFact) -> String {
        var parts = factParts(
            type: fact.type, date: fact.date, place: fact.place, value: fact.value)
        if !fact.supportedByLinks.isEmpty {
            parts.append("[cited by \(fact.supportedByLinks.count) source(s)]")
        }
        return parts.joined(separator: "  ")
    }

    // MARK: - Relationships

    /// How `other` relates to `subject`, phrased from the subject's point of view
    /// — the CLI twin of the app's perspective-based relationship rows.
    ///
    /// Reads the §4.5 storage convention resolved in slice 43: for
    /// `parent-child`, `person1Uid` is the **parent** and `person2Uid` the
    /// **child**; a `couple` is symmetric.
    static func role(of relationship: Relationship, from subject: PersonID) -> String {
        switch relationship.type {
        case .couple:
            return "partner"
        case .parentChild:
            return relationship.person1Uid == subject ? "child" : "parent"
        case .unknown(let raw):
            return raw
        }
    }

    /// The other endpoint of `relationship` relative to `subject`. For a
    /// self-referential record (both endpoints the same person) this is `subject`
    /// itself, which is what the caller should print.
    static func otherEndpoint(of relationship: Relationship, from subject: PersonID) -> PersonID {
        relationship.person1Uid == subject ? relationship.person2Uid : relationship.person1Uid
    }
}
