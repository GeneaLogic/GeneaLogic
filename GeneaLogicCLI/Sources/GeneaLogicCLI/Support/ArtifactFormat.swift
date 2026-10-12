import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// Shared rendering for the **artifact** (evidence-layer) commands — `show`, and
/// the `event`/`place` add echoes — the sibling of `ConclusionsFormat`.
///
/// The two are kept apart on purpose: `ConclusionsFormat` renders the
/// conclusion records (persons, relationships, facts), this renders the
/// evidence a document carries (events, locations, mentions, files). Both use
/// the same human `show`-style register — two-space-separated parts, absent
/// fields omitted rather than printed as empty columns — and both defer the EDTF
/// date gloss to `ConclusionsFormat.date`, so a date renders identically
/// wherever it appears.
enum ArtifactFormat {

    /// `"Census  1920 (1920)  Cook County, Illinois"` — an event's type, date
    /// (EDTF gloss when it differs) and location, with absent parts omitted.
    static func eventLine(_ event: Event) -> String {
        var parts = [event.type]
        if let date = event.date, !date.isEmpty { parts.append(ConclusionsFormat.date(date)) }
        if let location = event.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: "  ")
    }

    /// `"Cook County, Ill."` — or `"Cook County, Ill.  → Cook County, Illinois, USA"`
    /// when a normalized form is recorded.
    static func locationLine(_ location: Location) -> String {
        var parts = [location.asRecorded]
        if let normalized = location.normalized, !normalized.isEmpty {
            parts.append("→ \(normalized)")
        }
        return parts.joined(separator: "  ")
    }

    /// `"Anna Meyer  subject  primary  ru/Cyrl  age 28"` — a mention's
    /// name-as-recorded, role, and (when they add information) its quality, the
    /// name's language/script tags and the recorded age.
    static func mentionLine(_ mention: PersonMention) -> String {
        var parts = [mention.nameAsRecorded, mention.role.rawValue]
        if mention.informationQuality != .undetermined {
            parts.append(mention.informationQuality.rawValue)
        }
        if let tag = ConclusionsFormat.languageScriptTag(mention.nameLanguage, mention.nameScript) {
            parts.append(tag)
        }
        if let age = mention.attributes?["ageAsRecorded"], !age.isEmpty {
            parts.append("age \(age)")
        }
        return parts.joined(separator: "  ")
    }

    /// `"Birth  1892 (1892)  Łomża  secondary"` — one fact a document records about
    /// one of the people it names (`PersonMention.facts`, slice 44h).
    ///
    /// The quality column appears only when the fact *states* one: absent means it
    /// inherits the mention's, and printing the inherited value would misrepresent
    /// the record as having made a per-field judgment it didn't.
    ///
    /// Shares `ConclusionsFormat.factParts` with the conclusion-side `factLine`: the
    /// two fact types differ only in their trailing column, and the type/date/place
    /// prefix rendering identically on both sides is a promise this file's header
    /// already makes.
    static func recordedFactLine(_ fact: RecordedFact) -> String {
        var parts = ConclusionsFormat.factParts(
            type: fact.type, date: fact.date, place: fact.place, value: fact.value)
        if let quality = fact.informationQuality { parts.append(quality.rawValue) }
        return parts.joined(separator: "  ")
    }

    /// `"p2 → p1  parent-child"` — a relationship the document states between two of
    /// its mentions (slice 45k).
    ///
    /// The arrow is the §4.5 direction made visible (parent → child) and is drawn for
    /// every type, including the symmetric `couple`: a reader who has to remember which
    /// types are ordered will get it wrong, and `show` renders the *stored* pair in the
    /// stored order either way. `mentionRelationshipRow` is what pairs it with names.
    static func mentionRelationshipLine(_ edge: MentionRelationship) -> String {
        "\(edge.person1Ref) → \(edge.person2Ref)  \(edge.type.rawValue)"
    }

    /// The same edge with the two names spelled out — `"p2 → p1  parent-child  Marcus
    /// Feldberg → Sidney Feldberg"` — for `show`, where the refs alone say nothing.
    ///
    /// A ref the record no longer carries renders as `?`, never as a blank: that is the
    /// §2.3 dangle `genea verify` reports, and hiding it here would make `show` the one
    /// surface that quietly agrees with a broken record.
    static func mentionRelationshipRow(_ edge: MentionRelationship, in record: Artifact) -> String {
        func name(_ ref: String) -> String {
            record.personsMentioned.first { $0.localRef == ref }?.nameAsRecorded ?? "?"
        }
        return mentionRelationshipLine(edge)
            + "  \(name(edge.person1Ref)) → \(name(edge.person2Ref))"
    }

    /// `"census.tif  preservation-master  Census 1920.tif  1048576 bytes"` — the
    /// descriptive tail of a file row (the `show` Files section leads it with the
    /// `FIL-` uid, which is the addressable thing for `set-role`/`replace-file`/
    /// `detach`).
    static func fileLine(_ file: FileEntry) -> String {
        [file.path, file.role.rawValue, file.originalName, "\(file.byteLength) bytes"]
            .joined(separator: "  ")
    }
}
