import Foundation
import GeneaLogicModel

/// A conclusion record to write — the sidecar and its index row, together.
enum ConclusionWrite {
    case person(Person)
    case relationship(Relationship)
    case link(EvidenceLink)
    case dismissal(Dismissal)
}

/// A conclusion record to remove, by uid.
enum ConclusionRemoval {
    case person(PersonID)
    case relationship(RelationshipID)
    case link(EvidenceLinkID)
    case dismissal(DismissalID)
}

/// The one way a conclusion record is written or removed, so its path is spelled
/// in one place (`ArchiveLayout.recordURL`) and a cascade's pre-flight is built
/// from the same values it then executes (slice 68, `/code-review`).
extension Archive {
    func recordURL(of write: ConclusionWrite) -> URL {
        switch write {
        case .person(let person): ArchiveLayout.recordURL(in: rootURL, person: person.uid)
        case .relationship(let relationship):
            ArchiveLayout.recordURL(in: rootURL, relationship: relationship.uid)
        case .link(let link): ArchiveLayout.recordURL(in: rootURL, link: link.uid)
        case .dismissal(let dismissal):
            ArchiveLayout.recordURL(in: rootURL, dismissal: dismissal.uid)
        }
    }

    func recordURL(of removal: ConclusionRemoval) -> URL {
        switch removal {
        case .person(let id): ArchiveLayout.recordURL(in: rootURL, person: id)
        case .relationship(let id): ArchiveLayout.recordURL(in: rootURL, relationship: id)
        case .link(let id): ArchiveLayout.recordURL(in: rootURL, link: id)
        case .dismissal(let id): ArchiveLayout.recordURL(in: rootURL, dismissal: id)
        }
    }

    /// Writes the sidecar, then upserts the index row. Callable from inside an
    /// existing `withState`.
    func write(_ record: ConclusionWrite, index: ArchiveIndex) throws {
        try writeAuthoredJSON(record.value, to: recordURL(of: record))
        switch record {
        case .person(let person): try index.upsert(person)
        case .relationship(let relationship): try index.upsert(relationship)
        case .link(let link): try index.upsert(link)
        case .dismissal(let dismissal): try index.upsert(dismissal)
        }
    }

    /// Sidecar first, then the index row — the ordering every conclusions removal
    /// uses (a failure between the two reconciles *toward* deletion on the next
    /// rebuild; the reverse order would resurrect it).
    func remove(_ record: ConclusionRemoval, index: ArchiveIndex) throws {
        try removeAuthoredFile(at: recordURL(of: record))
        switch record {
        case .person(let id): try index.removePerson(id)
        case .relationship(let id): try index.removeRelationship(id)
        case .link(let id): try index.removeLink(id)
        case .dismissal(let id): try index.removeDismissal(id)
        }
    }

    /// Writes everything that stays, then removes what it displaced — **after
    /// checking every one of them against the drift guard** (slice 68, fork b).
    ///
    /// `withState` has no rollback, so a refusal part-way through a cascade would
    /// leave the steps before it standing and, having authored something, arm the
    /// interrupted-write flag. The pre-flight and the execution walk the same two
    /// lists, so a step added to a cascade is checked by construction.
    func applyCascade(
        writing writes: [ConclusionWrite], removing removals: [ConclusionRemoval],
        index: ArchiveIndex
    ) throws {
        try refuseToTouchDriftedRecords(
            at: writes.map(recordURL(of:)) + removals.map(recordURL(of:)))
        for record in writes { try write(record, index: index) }
        for record in removals { try remove(record, index: index) }
    }
}

extension ConclusionWrite {
    fileprivate var value: any Encodable {
        switch self {
        case .person(let person): person
        case .relationship(let relationship): relationship
        case .link(let link): link
        case .dismissal(let dismissal): dismissal
        }
    }
}
