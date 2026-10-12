import Foundation
import GeneaLogicModel

/// Referential integrity over the **conclusion** records (ARCHITECTURE.md §2.3,
/// §4.4, §4.5) — the counterpart to `Archive+Integrity.swift`, which audits the
/// evidence payload against `manifest.json`.
///
/// The two are deliberately separate surfaces: one hashes files, the other
/// resolves pointers, and neither is a subset of the other. See
/// `DanglingReference` for why the dangles exist at all (the §2.3 no-cascade
/// removal contract) rather than being prevented.
extension Archive {

    /// Finds every record that points at something that no longer exists — a
    /// relationship or link naming a removed `Person`, a link naming a removed
    /// `Artifact` or a removed `PersonMention`, a `supportedByLinks` citation whose
    /// `EvidenceLink` was unlinked, a dismissal (slice 45m) naming a removed `Person`,
    /// or (slice 45k) an artifact's own stated `mentionRelationships` edge naming a
    /// mention that was removed.
    ///
    /// The app already degrades gracefully wherever one of these surfaces at
    /// display time ("Unknown person" / "Unknown artifact", slices 42b/43); this
    /// is the sweep that makes them **findable in one pass** instead of only
    /// stumbled upon.
    ///
    /// Never throws: like `verifyIntegrity()`, content problems are the *output*,
    /// and a record kind the index can't read is skipped rather than failing the
    /// sweep (a genuinely broken `.index/` is `Archive.open`'s problem — it
    /// rebuilds).
    ///
    /// **Rejection tombstones are audited like any other link** — the one read surface
    /// in the engine that does *not* hide them (slice 45c; contrast `links(for:)`).
    /// Those accessors are conclusions views, where a tombstone must never read as a
    /// citation; this is an integrity sweep over the records actually on disk, and a
    /// tombstone naming a deleted artifact or person is exactly as much a dangling
    /// pointer as a confirmation is. Excluding them would make a class of garbage that
    /// nothing in the system can find — invisible to every query *and* to the sweep
    /// whose job is finding what queries hide. It is `unlink(_:)` that cleans one up,
    /// same as any link.
    ///
    /// - Returns: The findings in a deterministic order — evidence links first,
    ///   then relationships, then persons, then dismissals, then artifacts, each by
    ///   `uid` (a time-ordered UUIDv7, so creation order), and within a record in
    ///   field order. Empty when every reference resolves.
    public func findDanglingReferences() -> [DanglingReference] {
        withIndex { index in
            // Degraded **per kind**, not all-or-nothing: one unreadable table
            // shouldn't silently turn the whole sweep into "nothing dangling",
            // because nothing else audits the conclusion sidecars —
            // `verifyIntegrity()` is scoped to the manifest's file payload — so a
            // blanket empty result would let the panel affirm that every
            // conclusion resolves when it never managed to read them.
            let links = (try? index.allLinks()) ?? []
            let relationships = (try? index.allRelationships()) ?? []
            let persons = (try? index.allPersons()) ?? []
            let dismissals = (try? index.allDismissals()) ?? []

            // The persons and links are already in hand, so their existence is a
            // set membership test. The artifact records are kept whole, not just
            // their existence: the mention check needs `personsMentioned`.
            let personIDs = Set(persons.map(\.uid))
            let linkIDs = Set(links.map(\.uid))
            var artifactCache: [ArtifactID: Artifact?] = [:]

            // **Every artifact is decoded, once per sweep** — slice 45k's stated
            // relationships dangle *inside* a record, so unlike every other check here
            // there is no pointer to follow: the only way to find one is to look at all
            // of them. Until 45k this pass deliberately loaded artifacts one uid at a
            // time (a dangle is rare, so only the *referenced* records cost anything),
            // and that is no longer what happens; the honest cost is now one decode per
            // artifact in the archive, and the integrity panel re-runs the sweep after
            // each repair. `verifyIntegrity()` hashes the whole file payload beside it,
            // which is far more expensive, so this stays proportionate — but an archive
            // where it stops being proportionate wants an index projection for the
            // edges (45o's `place` projection is the pattern), not a subtler sweep.
            //
            // The bulk load also seeds the memo below, so the link checks read from it
            // instead of re-decoding. If it fails, the cache is simply empty and they
            // fall back to fetching one uid at a time, exactly as before.
            let artifacts = (try? index.allArtifacts()) ?? []
            for record in artifacts { artifactCache[record.uid] = record }

            func artifact(_ id: ArtifactID) -> Artifact? {
                if let cached = artifactCache[id] { return cached }
                let loaded = (try? index.artifact(id)) ?? nil
                artifactCache[id] = loaded
                return loaded
            }

            var found: [DanglingReference] = []

            for link in links.sorted(by: { $0.uid.raw < $1.uid.raw }) {
                if let artifact = artifact(link.artifactUid) {
                    // Only meaningful once the artifact is known to be present —
                    // otherwise the missing artifact is the finding, and the
                    // unresolvable mention is just a restatement of it.
                    if !artifact.personsMentioned.contains(where: {
                        $0.localRef == link.personMentionRef
                    }) {
                        found.append(
                            .linkMention(
                                link: link.uid, artifact: link.artifactUid,
                                missingRef: link.personMentionRef))
                    }
                } else {
                    found.append(.linkArtifact(link: link.uid, missingArtifact: link.artifactUid))
                }

                if !personIDs.contains(link.personUid) {
                    found.append(.linkPerson(link: link.uid, missingPerson: link.personUid))
                }
            }

            for relationship in relationships.sorted(by: { $0.uid.raw < $1.uid.raw }) {
                for endpoint in [relationship.person1Uid, relationship.person2Uid]
                where !personIDs.contains(endpoint) {
                    found.append(
                        .relationshipEndpoint(
                            relationship: relationship.uid, missingPerson: endpoint))
                }
                for support in relationship.supportedByLinks where !linkIDs.contains(support) {
                    found.append(
                        .relationshipSupport(relationship: relationship.uid, missingLink: support))
                }
                for (factIndex, fact) in relationship.facts.enumerated() {
                    for support in fact.supportedByLinks where !linkIDs.contains(support) {
                        found.append(
                            .relationshipFactSupport(
                                relationship: relationship.uid, factIndex: factIndex,
                                missingLink: support))
                    }
                }
            }

            for person in persons.sorted(by: { $0.uid.raw < $1.uid.raw }) {
                for (factIndex, fact) in person.facts.enumerated() {
                    for support in fact.supportedByLinks where !linkIDs.contains(support) {
                        found.append(
                            .personFactSupport(
                                person: person.uid, factIndex: factIndex, missingLink: support))
                    }
                }
            }

            for dismissal in dismissals.sorted(by: { $0.uid.raw < $1.uid.raw }) {
                for endpoint in [dismissal.person1Uid, dismissal.person2Uid]
                where !personIDs.contains(endpoint) {
                    found.append(
                        .dismissalEndpoint(dismissal: dismissal.uid, missingPerson: endpoint))
                }
            }

            // The evidence layer's own pointers (slice 45k): an edge naming a mention
            // the record no longer carries. Removing a mention strands its edge for the
            // same §2.3 reason it strands a link — the record keeps saying whose child
            // somebody was after the parent's row is gone — and an unfindable statement
            // is worse than a reported one.
            for record in artifacts.sorted(by: { $0.uid.raw < $1.uid.raw }) {
                let refs = Set(record.personsMentioned.map(\.localRef))
                for (edgeIndex, edge) in record.mentionRelationships.enumerated() {
                    for endpoint in [edge.person1Ref, edge.person2Ref]
                    where !refs.contains(endpoint) {
                        found.append(
                            .mentionRelationshipEndpoint(
                                artifact: record.uid, edgeIndex: edgeIndex,
                                missingRef: endpoint))
                    }
                }
            }

            // A record can name the same missing target twice — a self-relationship
            // with both endpoints gone, or a `supportedByLinks` that repeats a uid —
            // which would emit two byte-identical findings. Report each distinct
            // broken pointer once (first occurrence wins, so the order above holds).
            var seen: Set<DanglingReference> = []
            return found.filter { seen.insert($0).inserted }
        }
    }
}
