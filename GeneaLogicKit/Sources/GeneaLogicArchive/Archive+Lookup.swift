import Foundation
import GeneaLogicModel

/// The read surface (ARCHITECTURE.md §5.1, §6.3): point lookups, list/browse
/// summaries, and filtered queries over artifacts and concluded persons.
///
/// **FINAL surface, SQLite-backed:** every method here is backed by the
/// `.index/index.sqlite`-backed `ArchiveIndex` (see its doc comment). The
/// *shapes* returned (`Artifact`/`Person` snapshots, `ArtifactSummary`/
/// `PersonSummary`, `ArtifactQuery`/`PersonQuery`) and every method signature
/// in this file are unchanged from the in-memory-backed Phase 1a version — the
/// SQLite swap (Phase 1b) touched only `ArchiveIndex` and the call sites below,
/// per CLAUDE.md's "the lookup API is final." All reads go through `withIndex`,
/// taking a point-in-time snapshot consistent with "the index reflects the last
/// committed state" (§5.1). `try?`/`(try? … ) ?? […]` below silently treat a
/// SQL read failure as "nothing found"/"empty list" rather than `throws`-ing —
/// preserving these methods' non-throwing signatures (a hard constraint) while
/// `Archive.open`'s rebuild-on-corruption policy is what actually keeps
/// `.index/index.sqlite` healthy; a read failure here would mean something is
/// wrong between `open()` succeeding and this call, which `verifyIntegrity()`/
/// `rebuildIndex()` are the tools to diagnose, not a silent crash in a query.
extension Archive {

    // MARK: - Artifact point lookups

    /// Returns the full `Artifact` record for `id`, or `nil` if it doesn't exist.
    public func artifact(withID id: ArtifactID) -> Artifact? {
        withIndex { index in (try? index.artifact(id)) ?? nil }
    }

    /// Returns the artifact whose `record.json` lives at `path` (relative to the
    /// archive root, forward-slash form — the same shape as `ManifestEntry.path`
    /// and `ArchiveLayout.relativePath(of:in:)`), or `nil` if no artifact's
    /// folder matches.
    ///
    /// "Atness" is matched against the artifact's *folder* — `path` may name the
    /// folder itself (`"artifacts/<slug>"`), the `record.json` inside it
    /// (`"artifacts/<slug>/record.json"`), or any file the artifact owns
    /// (`"artifacts/<slug>/scan.tif"`) — all resolve to the same artifact, which
    /// matches "I see this folder/file in Finder, what artifact is it?" (§6.3).
    public func artifact(atPath path: String) -> Artifact? {
        withIndex { index in
            guard let slugs = try? index.allSlugs() else { return nil }
            let normalizedQuery = Self.normalizedRelativePath(path)
            for (artifactID, slug) in slugs {
                let folderPrefix = "\(ArchiveLayout.artifactsDirectoryName)/\(slug)"
                if normalizedQuery == folderPrefix
                    || normalizedQuery.hasPrefix(folderPrefix + "/")
                {
                    return (try? index.artifact(artifactID)) ?? nil
                }
            }
            return nil
        }
    }

    /// Returns the artifact carrying `externalID` among its
    /// `externalIdentifiers` (matched on `scheme` + `value`), or `nil`.
    public func artifact(withExternalIdentifier externalID: ExternalIdentifier) -> Artifact? {
        withIndex { index in
            let artifacts = (try? index.allArtifacts()) ?? []
            return artifacts.first { artifact in
                artifact.externalIdentifiers.contains {
                    $0.scheme == externalID.scheme && $0.value == externalID.value
                }
            }
        }
    }

    // MARK: - Artifact list/browse surfaces

    /// Returns a lightweight summary of every artifact in the archive, suitable
    /// for a browse/list view without decoding every full `record.json`.
    public func artifacts() -> [ArtifactSummary] {
        withIndex { index in
            let slugs = (try? index.allSlugs()) ?? [:]
            let artifacts = (try? index.allArtifacts()) ?? []
            return artifacts.map { Self.summarize($0, slug: slugs[$0.uid]) }
                .sorted { $0.title < $1.title }
        }
    }

    /// Returns summaries of every artifact matching `query` (ARCHITECTURE.md
    /// §5.1, §6.3: free text — *substring* — over title/transcript/notes, the text
    /// of `role: .transcript` files, **and the structured evidence fields**
    /// (persons-mentioned names, location text, and event type/date/location), plus
    /// an *exact* whole-tag match against `tags`; tag/source-tier/date filters; and
    /// "mentioning" a name-as-recorded substring). All non-empty fields combine with
    /// logical AND.
    ///
    /// **Reuses the Swift `matches` predicate, not SQL** — see `ArchiveIndex`'s
    /// doc comment for why: candidates come from `allArtifactsWithSearchText()` (a
    /// `SELECT *` over the `artifact` table, decoded, each paired with its indexed
    /// transcript-file text), filtered exactly as the in-memory version was.
    public func artifacts(matching query: ArtifactQuery) -> [ArtifactSummary] {
        withIndex { index in
            let slugs = (try? index.allSlugs()) ?? [:]
            let artifacts = (try? index.allArtifactsWithSearchText()) ?? []
            return
                artifacts
                .filter {
                    Self.matches($0.artifact, query: query, transcriptFileText: $0.searchText)
                }
                .map { Self.summarize($0.artifact, slug: slugs[$0.artifact.uid]) }
                .sorted { $0.title < $1.title }
        }
    }

    /// Returns summaries of every artifact that has at least one `EvidenceLink`
    /// connecting one of its person mentions to the concluded person `id`
    /// (ARCHITECTURE.md §5.1: "show me everything that mentions this person" —
    /// the conclusions-aware complement to `artifacts(matching:)`'s
    /// raw-text `mentioning`).
    ///
    /// Rejection tombstones are excluded — a record the user said does *not* name this
    /// person is not a record mentioning them, which is the whole content of the answer
    /// here (slice 45c).
    public func artifacts(mentioning id: PersonID) -> [ArtifactSummary] {
        withIndex { index in
            let links = (try? index.allLinks()) ?? []
            let linkedArtifactIDs = Set(
                links
                    .filter { $0.personUid == id && !$0.isRejection }
                    .map(\.artifactUid)
            )
            let slugs = (try? index.allSlugs()) ?? [:]
            let artifacts = (try? index.allArtifacts()) ?? []
            return
                artifacts
                .filter { linkedArtifactIDs.contains($0.uid) }
                .map { Self.summarize($0, slug: slugs[$0.uid]) }
                .sorted { $0.title < $1.title }
        }
    }

    /// Returns summaries of every artifact that owns at least one `FileEntry`
    /// whose `sha256` equals `sha256` — the archive-wide complement to
    /// `attachFile`'s same-artifact `duplicatesOf` (ARCHITECTURE.md §4.2.1, §10
    /// open question 6: "has this exact file been ingested anywhere before?").
    ///
    /// The candidate-id lookup (`artifactIDs(withFileSHA256:)`) hits the
    /// indexed `file.sha256` column — a genuine equality lookup, unlike
    /// `matching:`/`mentioning:` above.
    public func artifacts(containingFileWithSHA256 sha256: String) -> [ArtifactSummary] {
        withIndex { index in
            guard let ids = try? index.artifactIDs(withFileSHA256: sha256), !ids.isEmpty else {
                return []
            }
            let slugs = (try? index.allSlugs()) ?? [:]
            let artifacts = (try? index.allArtifacts()) ?? []
            return
                artifacts
                .filter { ids.contains($0.uid) }
                .map { Self.summarize($0, slug: slugs[$0.uid]) }
                .sorted { $0.title < $1.title }
        }
    }

    // MARK: - Person point lookups & list/browse surfaces

    /// Returns the full `Person` record for `id`, or `nil` if it doesn't exist.
    public func person(withID id: PersonID) -> Person? {
        withIndex { index in (try? index.person(id)) ?? nil }
    }

    /// Returns a lightweight summary of every concluded person in the archive.
    public func persons() -> [PersonSummary] {
        withIndex { index in
            let persons = (try? index.allPersons()) ?? []
            return persons.map(Self.summarize)
                .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
        }
    }

    /// Returns summaries of every concluded person matching `query`
    /// (ARCHITECTURE.md §6.3: "Persons have the parallel surface" to
    /// `artifacts(matching:)` — free text over names/fact places, fact-type and
    /// date-range filters). Reuses the Swift `matches` predicate, same rationale
    /// as `artifacts(matching:)` above.
    public func persons(matching query: PersonQuery) -> [PersonSummary] {
        withIndex { index in
            let persons = (try? index.allPersons()) ?? []
            return
                persons
                .filter { Self.matches($0, query: query) }
                .map(Self.summarize)
                .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
        }
    }

    // MARK: - Relationship & evidence-link read surfaces

    /// Returns every concluded relationship in the archive, ordered by `uid` (a
    /// time-ordered UUIDv7, so this is creation order). The Tree view reads the
    /// full set alongside `persons()` to derive the graph.
    public func relationships() -> [Relationship] {
        withIndex { index in
            ((try? index.allRelationships()) ?? []).sorted { $0.uid.raw < $1.uid.raw }
        }
    }

    /// Returns the full `Relationship` record for `id`, or `nil` if it doesn't exist.
    /// The relationship analog of `person(withID:)` — the app reads a before-snapshot
    /// through this ahead of an undoable `updateRelationship`.
    public func relationship(withID id: RelationshipID) -> Relationship? {
        withIndex { index in (try? index.relationship(id)) ?? nil }
    }

    /// Returns every relationship in which `id` participates as either endpoint
    /// (`person1Uid` or `person2Uid`) — a person's relatives, for the person
    /// detail and tree navigation.
    public func relationships(of id: PersonID) -> [Relationship] {
        withIndex { index in
            ((try? index.allRelationships()) ?? [])
                .filter { $0.person1Uid == id || $0.person2Uid == id }
                .sorted { $0.uid.raw < $1.uid.raw }
        }
    }

    /// Returns the full `EvidenceLink` record for `id`, or `nil` if it doesn't exist —
    /// the link analog of `person(withID:)` / `relationship(withID:)`. Both `links(for:)`
    /// accessors are *filtered views*, so a consumer holding a bare link uid (a
    /// `supportedByLinks` citation, or a `DanglingReference` finding) has no other way to
    /// read its endpoints.
    public func evidenceLink(withID id: EvidenceLinkID) -> EvidenceLink? {
        withIndex { index in (try? index.evidenceLink(id)) ?? nil }
    }

    // MARK: Evidence links — and why rejections are hidden
    //
    // Both accessors below drop `.humanRejected` links unless asked for them (slice
    // 45c). A rejection tombstone is stored as an `EvidenceLink` because that is what
    // §4.4's three-state `reviewStatus` has always described — but it is the record of
    // a *refusal*, and every consumer of these accessors treats a returned link as a
    // citation. Ship them unfiltered and the person detail lists "sources" the user
    // explicitly said were not them, `artifacts(mentioning:)` returns records that
    // don't mention them, and a fact could cite the proof that it is wrong. The
    // tombstone would silently resurrect as evidence — the one failure mode this slice
    // exists to prevent.
    //
    // Hiding by **default**, rather than asking every caller to filter, is the point: a
    // call site added next year that thinks about none of this still gets the safe
    // answer, and the paths that genuinely want tombstones (un-rejecting one, showing a
    // reviewer why a pair stopped being offered) say so out loud at the point of use.
    // `evidenceLink(withID:)` is deliberately **not** filtered — it resolves a uid the
    // caller already holds, and refusing to return a record it can name would read as
    // corruption rather than as policy.

    /// Returns **every** evidence link in the archive, for a consumer that needs all of
    /// them at once and will group them itself.
    ///
    /// Exists because both filtered accessors below decode the whole `link` table on each
    /// call, so asking them person by person is O(persons × all-links) decodes to answer
    /// one archive-wide question (slice 45i's cross-person suggested-facts sweep — the
    /// same shape 45e rejected when it added archive-wide `suggestLinks`). Use a filtered
    /// accessor whenever one endpoint is known; reach for this only when the answer really
    /// is about the whole corpus.
    ///
    /// Rejections are excluded unless `includeRejected` is `true` — the citation reading,
    /// same default and same reason as its two siblings.
    public func links(includeRejected: Bool = false) -> [EvidenceLink] {
        withIndex { index in
            ((try? index.allLinks()) ?? [])
                .filter { includeRejected || !$0.isRejection }
                .sorted { $0.uid.raw < $1.uid.raw }
        }
    }

    /// Returns every evidence link pointing at the concluded person `id` — the
    /// evidence behind that person's facts (each link ties one artifact mention to
    /// this person; ARCHITECTURE.md §4.4). A `PersonFact.supportedByLinks` entry
    /// resolves against this set.
    ///
    /// Rejections are excluded unless `includeRejected` is `true`.
    public func links(
        for id: PersonID, includeRejected: Bool = false
    ) -> [EvidenceLink] {
        withIndex { index in
            ((try? index.allLinks()) ?? [])
                .filter { $0.personUid == id && (includeRejected || !$0.isRejection) }
                .sorted { $0.uid.raw < $1.uid.raw }
        }
    }

    /// Returns every evidence link originating from a mention in artifact `id` —
    /// i.e. which of the artifact's `personsMentioned` have been resolved to a
    /// concluded person, for the inspector's Persons Mentioned section.
    ///
    /// Rejections are excluded unless `includeRejected` is `true`.
    public func links(
        forArtifact id: ArtifactID, includeRejected: Bool = false
    ) -> [EvidenceLink] {
        withIndex { index in
            ((try? index.allLinks()) ?? [])
                .filter { $0.artifactUid == id && (includeRejected || !$0.isRejection) }
                .sorted { $0.uid.raw < $1.uid.raw }
        }
    }

    // MARK: - Summarization helpers

    /// Builds an `ArtifactSummary` snapshot from a full `Artifact` (+ its slug,
    /// captured at index-build/upsert time — see `ArchiveIndex.artifactSlugs`).
    /// `slug` should never be `nil` for an artifact the index actually holds
    /// (every `upsert` records one); the empty-string fallback only guards
    /// against an inconsistent index, which `verifyIntegrity`/`rebuildIndex`
    /// would be the place to detect and fix.
    private static func summarize(_ artifact: Artifact, slug: String?) -> ArtifactSummary {
        ArtifactSummary(
            uid: artifact.uid,
            title: artifact.title,
            slug: slug ?? "",
            mediaType: artifact.mediaType,
            sourceAuthorityTier: artifact.sourceAuthorityTier,
            primaryDate: earliestDate(of: artifact.events.map(\.date)),
            tags: artifact.tags,
            fileCount: artifact.files.count
        )
    }

    /// Builds a `PersonSummary` snapshot from a full `Person`.
    ///
    /// Display-name resolution is a **format-level rule** shared with the app and
    /// the CLI, so it lives on `Person` in the model (slice 44c) rather than being
    /// restated here — see ``Person/displayName`` for the derivation.
    ///
    /// Note that move also *normalized* two degenerate cases this used to get
    /// wrong: whitespace-only text now counts as no name, and a blank `given` no
    /// longer leaves a leading space in a derived `full`. Both affect only
    /// malformed data, but it isn't a pure code move.
    private static func summarize(_ person: Person) -> PersonSummary {
        PersonSummary(
            uid: person.uid,
            displayName: person.displayName,
            primaryDate: earliestDate(of: person.facts.map(\.date)),
            factCount: person.facts.count
        )
    }

    /// The chronologically-earliest date string among `dates`, returned verbatim.
    ///
    /// Each value is parsed as EDTF (ISO 8601-2) and ordered by its earliest bound
    /// (``EDTFDate/sortBound``), so approximate/ranged/masked forms sort correctly —
    /// `1920~` before `1925`, `1900/1905` by its 1900 start — where a plain
    /// lexicographic string sort would not (`~`/`..` sort as punctuation). A value
    /// that isn't valid EDTF can't be placed chronologically and is skipped; if none
    /// are parseable the result is `nil`. (Legacy ISO dates are all valid EDTF, so no
    /// existing archive loses its primary date.)
    private static func earliestDate(of dates: [String?]) -> String? {
        dates.compactMap { $0 }
            .compactMap { raw in EDTFDate.parse(raw)?.sortBound.map { (raw, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: - Query predicates

    /// - Parameter transcriptFileText: The indexed text of the artifact's
    ///   `role: .transcript` files (`ArchiveIndex.search_text`), folded into the
    ///   free-text haystack so search covers transcripts stored as files, not just
    ///   the inline `artifact.transcript`. `nil` when the artifact has none.
    private static func matches(
        _ artifact: Artifact, query: ArtifactQuery, transcriptFileText: String? = nil
    ) -> Bool {
        if let text = query.text, !text.isEmpty {
            let needle = text.lowercased()
            // Free text is a *substring* match over the artifact's descriptive text
            // (title/transcript/notes + the text of any `role: .transcript` file) **and
            // its structured evidence fields** — the names it records, the places it
            // names, and its events — so a search for a person or place that lives only
            // in metadata still finds the record (these fields are all in the decoded
            // artifact, so no index column is needed; only file text needs `search_text`).
            var haystackParts = [
                artifact.title, artifact.transcript, artifact.notes, transcriptFileText,
            ]
            haystackParts += artifact.personsMentioned.map(\.nameAsRecorded)
            // What the record says *about* each person it names (slice 44h). Without
            // this, a mention-scoped birth place would be the one piece of evidence
            // the record states that free text can't reach — and on a multi-person
            // record that is where the dates and places increasingly live.
            haystackParts += artifact.personsMentioned.flatMap(\.facts).flatMap {
                [$0.type.rawValue, $0.date, $0.place, $0.value]
            }
            haystackParts += artifact.locations.flatMap { [$0.asRecorded, $0.normalized] }
            haystackParts += artifact.events.flatMap { [$0.type, $0.date, $0.location] }
            let haystack =
                haystackParts
                .compactMap { $0 }
                .joined(separator: "\n")
                .lowercased()
            // …OR an *exact* (whole-tag, case-insensitive) match against a tag. Tags are
            // atomic labels, so partial-matching them ("mar" → "marriage") would be
            // noisy; the structured `query.tags` facet (exact AND) stays separate for the
            // tag-filter UI.
            let tagHit = artifact.tags.contains { $0.lowercased() == needle }
            guard haystack.contains(needle) || tagHit else { return false }
        }

        if !query.tags.isEmpty {
            let artifactTags = Set(artifact.tags.map { $0.lowercased() })
            guard query.tags.allSatisfy({ artifactTags.contains($0.lowercased()) }) else {
                return false
            }
        }

        // Folded, not `!=`: a stored spelling an older build wrote as `.unknown` must keep
        // matching a query that this build folds to a now-known case (see
        // `OpenVocabulary.denotesSameTerm(as:)` — slice 46 broke exactly this by promoting
        // `government`).
        // An **uncharacterised** artifact matches no tier query (46b): asking for `vital`
        // must not return records that simply haven't been catalogued, or the filter would
        // quietly widen as the archive grows less complete.
        if let sourceTier = query.sourceTier {
            guard let tier = artifact.sourceAuthorityTier,
                tier.denotesSameTerm(as: sourceTier)
            else { return false }
        }

        if let dateRange = query.dateRange {
            // Every date the record states, wherever it states it: its events, and the
            // facts scoped to the people it names (slice 44h). Widening this is purely
            // additive — an artifact that matched before still matches — and without it
            // a record whose dates are all mention-scoped would be invisible to a year
            // filter despite being squarely in range.
            let recordedDates =
                artifact.events.map(\.date)
                + artifact.personsMentioned.flatMap(\.facts).map(\.date)
            guard
                recordedDates.contains(where: { date in
                    guard let edtf = date.flatMap(EDTFDate.parse) else { return false }
                    return edtf.overlaps(years: dateRange)
                })
            else {
                return false
            }
        }

        if let mentioning = query.mentioning, !mentioning.isEmpty {
            let needle = mentioning.lowercased()
            guard
                artifact.personsMentioned.contains(where: {
                    $0.nameAsRecorded.lowercased().contains(needle)
                })
            else {
                return false
            }
        }

        return true
    }

    private static func matches(_ person: Person, query: PersonQuery) -> Bool {
        if let text = query.text, !text.isEmpty {
            let needle = text.lowercased()
            let nameHaystack = person.names.flatMap { [$0.given, $0.surname, $0.full] }
                .compactMap { $0 }
            // A fact's place *and* its value (occupation "tailor", a physical
            // description) — so a person is findable by what their facts record, not
            // only their names (slice 44i, additive).
            let factHaystack = person.facts.flatMap { [$0.place, $0.value] }.compactMap { $0 }
            let haystack = (nameHaystack + factHaystack).joined(separator: "\n").lowercased()
            guard haystack.contains(needle) else { return false }
        }

        if !query.factTypes.isEmpty {
            guard person.facts.contains(where: { query.factTypes.contains($0.type) }) else {
                return false
            }
        }

        if let dateRange = query.dateRange {
            guard
                person.facts.contains(where: { fact in
                    guard let edtf = fact.date.flatMap(EDTFDate.parse) else { return false }
                    return edtf.overlaps(years: dateRange)
                })
            else {
                return false
            }
        }

        return true
    }

    /// Normalizes a caller-supplied path to the forward-slash,
    /// archive-root-relative form used by `ManifestEntry.path` and
    /// `ArchiveLayout.relativePath(of:in:)`, so `artifact(atPath:)` accepts
    /// either form a caller might reasonably have in hand (a path copied from a
    /// `ManifestEntry`, or one a UI assembled with a leading/trailing slash).
    private static func normalizedRelativePath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
