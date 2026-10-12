import Foundation
import GeneaLogicModel

/// Lightweight read-surface types (ARCHITECTURE.md §5.1, §6.3).
///
/// **PROVISIONAL / NOT FINAL BACKING:** the public *shapes* below
/// (`ArtifactSummary`, `PersonSummary`, `ArtifactQuery`, `PersonQuery`) are meant
/// to be the long-term public surface — §5.1 says "two return shapes exist on
/// purpose" and the §6.3 sketch fixes their field lists. What's provisional is
/// the *backing*: Phase 1 builds them from an in-memory index assembled on
/// `open()` by walking the sidecars; Phase "SQLite spike" replaces that backing
/// with `.index/index.sqlite` without changing any of these public types or the
/// `archive.artifacts(...)`/`archive.persons(...)` method signatures. Comments at
/// each call site in `Archive+Lookup.swift` repeat this so it isn't lost.

// MARK: - ArtifactSummary

/// A lightweight, list-friendly view of an artifact — everything a browse/search
/// result needs without decoding the full `record.json`.
public struct ArtifactSummary: Sendable, Equatable, Hashable {
    public var uid: ArtifactID
    public var title: String
    /// The on-disk folder slug, e.g. `"1920-us-census-smith-family"`. Friendly,
    /// non-authoritative (ARCHITECTURE.md §4.1) — shown for "I see this folder in
    /// Finder" lookups (`archive.artifact(atPath:)` in §6.3, not yet built here;
    /// flagged below).
    public var slug: String
    public var mediaType: MediaType
    /// Optional since 46b — absent means the artifact has not been characterised, which
    /// a summary must be able to say rather than inventing a genre for it.
    public var sourceAuthorityTier: SourceAuthorityTier?
    /// The earliest recorded event date, if any — a representative "primary
    /// date" for sorting/display. (`Event.date` is a possibly-partial ISO 8601
    /// string; this is the lexicographically-smallest non-nil one, which sorts
    /// correctly for `YYYY`/`YYYY-MM`/`YYYY-MM-DD` forms — the only forms the
    /// model currently produces.)
    public var primaryDate: String?
    public var tags: [String]
    public var fileCount: Int

    public init(
        uid: ArtifactID,
        title: String,
        slug: String,
        mediaType: MediaType,
        sourceAuthorityTier: SourceAuthorityTier?,
        primaryDate: String?,
        tags: [String],
        fileCount: Int
    ) {
        self.uid = uid
        self.title = title
        self.slug = slug
        self.mediaType = mediaType
        self.sourceAuthorityTier = sourceAuthorityTier
        self.primaryDate = primaryDate
        self.tags = tags
        self.fileCount = fileCount
    }
}

// MARK: - PersonSummary

/// A lightweight, list-friendly view of a concluded person.
public struct PersonSummary: Sendable, Equatable, Hashable {
    public var uid: PersonID
    /// The person's `full` display name, preferring a `.birth`-typed name and
    /// falling back to the first available name; `nil` if the person has none.
    public var displayName: String?
    /// The earliest recorded fact date (mirrors `ArtifactSummary.primaryDate`'s
    /// sort-friendly lexicographic-min-of-non-nil approach) — typically a birth.
    public var primaryDate: String?
    public var factCount: Int

    public init(
        uid: PersonID,
        displayName: String?,
        primaryDate: String?,
        factCount: Int
    ) {
        self.uid = uid
        self.displayName = displayName
        self.primaryDate = primaryDate
        self.factCount = factCount
    }
}

// MARK: - ArtifactQuery

/// An index-backed filter predicate for `artifacts(matching:)`
/// (ARCHITECTURE.md §5.1, §6.3).
///
/// All fields are optional/empty-meaning-"no filter"; non-nil/non-empty fields
/// combine with logical AND. `text` is matched (case-insensitively, substring)
/// against `title`, the inline `transcript`, `notes`, and the text of any
/// `role: .transcript` *file* — the fields §5.1 names as the "free text over
/// title/transcript/notes" surface, with transcript covering both the inline
/// field and file form.
public struct ArtifactQuery: Sendable, Equatable {
    public var text: String?
    public var tags: [String]
    public var sourceTier: SourceAuthorityTier?
    public var dateRange: ClosedRange<Int>?
    public var mentioning: String?

    public init(
        text: String? = nil,
        tags: [String] = [],
        sourceTier: SourceAuthorityTier? = nil,
        dateRange: ClosedRange<Int>? = nil,
        mentioning: String? = nil
    ) {
        self.text = text
        self.tags = tags
        self.sourceTier = sourceTier
        self.dateRange = dateRange
        self.mentioning = mentioning
    }
}

// MARK: - PersonQuery

/// The person-side parallel to `ArtifactQuery` (§6.3: "Persons have the parallel
/// surface"). Free text matches against names (`given`/`surname`/`full`) and
/// `facts[].place`; `factTypes`/`dateRange` filter on `facts[].type`/`.date`.
public struct PersonQuery: Sendable, Equatable {
    public var text: String?
    public var factTypes: [FactType]
    public var dateRange: ClosedRange<Int>?

    public init(
        text: String? = nil,
        factTypes: [FactType] = [],
        dateRange: ClosedRange<Int>? = nil
    ) {
        self.text = text
        self.factTypes = factTypes
        self.dateRange = dateRange
    }
}

// MARK: - AttachedFile

/// The result of `attachFile`: the created `FileEntry` plus whatever the
/// (optional) injected `MetadataExtractor` captured.
///
/// **Why a wrapper and not a bare `FileEntry`:** the §6.3 sketch shows
/// `attachFile` returning a `FileEntry`, but the embedded-metadata seam (§6.4)
/// needs *somewhere* to surface captured `EmbeddedMetadata` without persisting
/// it (see the NOTE in `EmbeddedMetadata.swift`). Returning it alongside the
/// `FileEntry` keeps the seam's output visible to the caller (who can log it,
/// show it in an ingest-review UI, or persist a `machine-suggested`
/// representation later) without smuggling a new field into the persisted model.
/// `AttachedFile` is `Equatable` via `FileEntry` + `EmbeddedMetadata`'s own
/// conformances; conforms to the same value-type conventions as the rest of the
/// public surface.
public struct AttachedFile: Sendable, Equatable {
    /// The created file entry, as recorded in `record.json`/`manifest.json`.
    public var entry: FileEntry

    /// Embedded metadata captured by the injected extractor, or `nil` if no
    /// extractor was supplied. An extractor that ran but found nothing returns
    /// an empty (non-nil) `EmbeddedMetadata`, distinguishable via `.isEmpty`.
    public var embeddedMetadata: EmbeddedMetadata?

    /// Other files in the same artifact already carrying byte-identical content
    /// (same `sha256`), surfaced for the optional content-de-duplication report
    /// (ARCHITECTURE.md §4.2.1, §10 open question 6). Empty when no duplicate was
    /// found. The new file is *always* stored — see the de-dup judgment call in
    /// `Archive+Files.swift` — this is purely informational for the caller.
    public var duplicatesOf: [FileEntry]

    public init(
        entry: FileEntry,
        embeddedMetadata: EmbeddedMetadata? = nil,
        duplicatesOf: [FileEntry] = []
    ) {
        self.entry = entry
        self.embeddedMetadata = embeddedMetadata
        self.duplicatesOf = duplicatesOf
    }
}

// MARK: - UnreadableRecordReason

/// Why an index rebuild skipped a record — see `IntegrityReport.Issue.unreadableRecord`.
///
/// Persisted in `.index/` as its raw value, so the strings are part of the index's
/// (rebuildable) schema, not of the archive format.
public enum UnreadableRecordReason: String, Sendable, Equatable, Hashable, CaseIterable {
    /// The file could not be read, or its bytes did not decode as the record
    /// its path says it is (slice 55). Damage, or a record from a build this one
    /// cannot decode at all; `Archive.repairRecord` may have a copy.
    case undecodable
    /// The file decoded, but its `schemaVersion` is older than the manifest's
    /// (slice 64, fork c): a straggler — an edit made on a machine still on the
    /// older build, landing after the archive was upgraded. Not damage. It is
    /// skipped because the archive-wide version rule (spec §8) says a record
    /// is loaded at the archive's version or not at all, and reported with its
    /// own reason so nothing offers to *repair* it.
    case olderFormat
}

/// One record an index rebuild skipped, and why — the row of `unreadable_record`.
public struct UnreadableRecord: Sendable, Equatable, Hashable {
    /// Archive-relative path of the record.
    public let path: String
    public let reason: UnreadableRecordReason

    public init(path: String, reason: UnreadableRecordReason) {
        self.path = path
        self.reason = reason
    }
}

// MARK: - IntegrityReport

/// The result of `verifyIntegrity()` (ARCHITECTURE.md §3, §6.3).
public struct IntegrityReport: Sendable, Equatable {
    /// A single integrity problem found during verification.
    public enum Issue: Sendable, Equatable {
        /// A file listed in the manifest has a different SHA-256 than recorded
        /// (bit rot / silent corruption / out-of-band edit).
        case checksumMismatch(path: String, expected: String, actual: String)
        /// A file listed in the manifest is absent on disk.
        case missingFile(path: String)
        /// A file's size on disk differs from the manifest's recorded `byteLength`
        /// (checked independently of the checksum so a short-read is diagnosable
        /// even when hashing the truncated file happens to still mismatch).
        case sizeMismatch(path: String, expected: Int64, actual: Int64)
        /// A file exists on disk inside the archive but is referenced by neither
        /// an artifact's `record.json` nor the manifest ("orphaned"/"extra" file).
        case unreferencedFile(path: String)
        /// An engine-authored file (a `record.json`, a `conclusions/**` record)
        /// whose contents don't match the manifest **on an archive that was
        /// opened with an unresolved `.index/dirty` sentinel** — some earlier
        /// mutation died between writing the file and committing the manifest
        /// (slice 49, fork e).
        ///
        /// Byte-for-byte this is indistinguishable from `.checksumMismatch`; the
        /// difference is what the archive knows about its own history. A stale
        /// hash left by a killed write is *suspect*, not *corrupt* — quite
        /// possibly the file is the newer, wanted version and the manifest is
        /// behind.
        ///
        /// **It does not promise the file is intact.** The sentinel records that
        /// *a* write died, never which record was in flight, so this is a
        /// classification and not a repair, and it is reported for every
        /// engine-authored mismatch until a `rebaseline()` resolves it — damage
        /// that happens to arrive in the same window is described this way too.
        /// The user is told which file, and that a write died somewhere; they are
        /// not told the contents are fine.
        case interruptedWrite(path: String)
        /// A file the manifest describes whose bytes are not (yet) the ones it
        /// describes, **on an archive whose index knows a delivery is still
        /// incomplete** (slice 60, hand-test).
        ///
        /// Sync is not atomic across files: another machine's `manifest.json` can
        /// arrive minutes before the record it names, or before a large
        /// preservation master finishes downloading. In that window the manifest
        /// is *ahead* of the disk, and every ordinary check is right to notice —
        /// but `.missingFile` and `.checksumMismatch` accuse the archive of
        /// damage it does not have, and on the app's banner that is the one
        /// surface 57 built specifically never to cry wolf.
        ///
        /// **The signal is that `manifest.json` is not the one the index last
        /// settled** — the manifest changed to something we have not yet been able
        /// to account for in full, which only a change from elsewhere can do.
        /// *Deliberately not "the index has no witness", which was tried first and
        /// is circular:* `manifestDeliveryLooksComplete` is false for **any**
        /// mismatch, exactly what `verifyIntegrity()` reports, so clearing the
        /// witness on damage made every damaged archive claim to be receiving a
        /// delivery. Corruption does not change `manifest.json`, and that
        /// asymmetry is the whole distinction. It is exactly the shape of 49's
        /// `.interruptedWrite` — the archive knowing something about its own
        /// history that the bytes cannot tell you — for a change arriving from
        /// elsewhere rather than one of ours that died.
        ///
        /// **Same known trade as `.interruptedWrite`, stated rather than hidden:**
        /// the witness is archive-wide, so it says *a* delivery is in flight, not
        /// *which* files it covers. Genuine damage that happens to occur during
        /// one is described this way too. It is a classification, not a promise,
        /// and it clears itself the moment the delivery completes and the next
        /// reconcile settles.
        ///
        /// **`rebaseline()` is the wrong answer here and must not be offered.**
        /// Blessing the local bytes mid-delivery records the *stale* version as
        /// the truth; the incoming record then lands as a reported corruption
        /// rather than an adoption, and the change made on the other machine is
        /// discarded. Waiting is the whole remedy.
        case awaitingDelivery(path: String)
        /// A record the last index rebuild could not read or decode, and so
        /// **skipped** — it is on disk but absent from every query (slice 55).
        ///
        /// Reported from what the rebuild recorded, not by re-decoding every
        /// record here. The two halves compose: on a healthy index, a sidecar
        /// damaged out-of-band is caught by its manifest checksum, and the case
        /// where a record is undecodable *and* missing from the index is exactly
        /// the case where a rebuild ran. So this says something the hash checks
        /// cannot — *this record is not in the index* — rather than duplicating
        /// them, and a record that is unreadable will usually be reported twice,
        /// once per question — "usually" because a record that decodes wrong but
        /// whose *bytes* still match the manifest (one written by a newer
        /// GeneaLogic) is reported only here, which is why this is its own kind.
        ///
        /// That pairing only holds because the manifest keeps its entry for a
        /// skipped record instead of dropping it — see `recomputeManifestFiles`,
        /// where the coupling is load-bearing and was once wrong (review
        /// finding, 55).
        ///
        /// A `rebaseline()` does not resolve it: that accepts the disk as truth,
        /// and the disk is where the unreadable file is. It clears when the file
        /// is repaired or removed and the index is rebuilt.
        ///
        /// **`reason` says why it was skipped** (slice 64, fork e), because since
        /// that slice one of them is not damage: a record whose format stamp is
        /// older than the archive's reads perfectly and is skipped anyway, for
        /// migration to bring forward. It shares this finding — same table, same
        /// consequence, *absent from every query* — and differs in what may be
        /// done about it: `Archive.repairRecord` refuses it, since restoring a
        /// preserved copy over an intact older record is a downgrade, not a
        /// repair.
        case unreadableRecord(path: String, reason: UnreadableRecordReason)
        /// A second file on disk claiming to be a record the archive already has
        /// — a sync provider's conflicted copy (slice 50c).
        ///
        /// Dropbox writes `X (Ada's conflicted copy 2026-08-29).json` beside `X`
        /// when it cannot merge one file; iCloud writes `X 2.json`; duplicating
        /// a whole `artifacts/<slug>/` folder does the same thing one level up.
        /// Until this slice both were **loaded**: the copy went into the index
        /// under the same uid as the original, `contentsOfDirectory` order
        /// decided which one every query returned, and the next ordinary mutation
        /// wrote that winner back over the canonical sidecar — silent data loss
        /// through the normal path, with `verifyIntegrity()` reporting a clean
        /// archive throughout. `RecordDiscovery` now settles which file *is* the
        /// record, and this says out loud what the other one is.
        ///
        /// **The path named is the copy, never the record.** Whatever the archive
        /// is serving is the file the rules chose, so this finding is never a
        /// reason to doubt what is on screen. For a duplicated artifact *folder*
        /// it names the loser's `record.json` — one finding per duplicated
        /// record, rather than one per file in a folder that may hold a
        /// preservation master too.
        ///
        /// **Nothing moves it, and nothing should.** `.damaged/` is the wrong
        /// shape (that directory holds bytes a repair had to *displace*; here the
        /// real file is already in place and untouched), quarantining would mutate
        /// the package on a read, the provider re-delivers the copy until the
        /// conflict is resolved at its source, and these bytes are the only copy
        /// of what the other machine wrote. So it is reported and left exactly
        /// where it is, for a human to read before they delete it.
        ///
        /// Deliberately **not** `.unreferencedFile`, which means *extra payload
        /// nobody claims* and reads as junk. This one holds a version of the
        /// user's data, and the advice differs accordingly.
        case conflictingCopy(path: String)
        /// A file that holds a record but is **not named for it**, on an archive
        /// where no file with the right name holds it either — so the record is
        /// on disk and in nothing (slice 50c, `/code-review`).
        ///
        /// The sibling of `.conflictingCopy`, and the reason that one can promise
        /// what it promises. A provider resolving a conflict sometimes renames
        /// the *original* rather than the copy, and a human renaming a sidecar
        /// does the same thing on purpose; the archive then declines to load it
        /// — correctly, since a file is the record only under the record's own
        /// name — and it would be reported as a second copy of something that is
        /// not there, with advice to delete it. That advice would destroy the
        /// only copy.
        ///
        /// **Its `.missingFile` companion is not a substitute.** The manifest
        /// entry for the canonical path is what reports the absence, and
        /// `recomputeManifestFiles` drops that entry on the next ordinary
        /// mutation — after which the deletion advice would be the only thing
        /// left standing. This one is derived from the disk on every verify and
        /// says which file and which `uid`, so the remedy is stateable: rename it
        /// to `<uid>.json`.
        ///
        /// `rebaseline()` does not resolve it, for `.unreadableRecord`'s reason:
        /// blessing what is on disk cannot conjure a file under the name the
        /// archive looks for.
        case misnamedRecord(path: String, uid: String)
    }

    public var issues: [Issue]

    /// Paths a human told this machine to **stop waiting for**
    /// (`Archive.abandonDelivery(path:)`, slice 50d).
    ///
    /// **Beside `issues`, deliberately not among them.** Nothing here is wrong
    /// with the archive — the entry an abandonment leaves is a perfectly ordinary
    /// one, minted from the file that is actually here — so putting it in
    /// `issues` would make `isClean` false for ever and turn a decision the user
    /// made into a standing accusation. What it must not be is *silent*: the
    /// manifest entry an abandonment mints is indistinguishable from one an
    /// ordinary commit mints, so without this note there is nothing on disk that
    /// answers "why does this record hold my version and not theirs?".
    ///
    /// The note clears itself when the path's entry moves again — the version
    /// lands after all, or the record is edited here. It is *filtered* by
    /// `Archive.standingAbandonments(against:on:)` and actually **deleted** by
    /// `Archive.pruneStaleAbandonments(against:on:)` on the next commit, which
    /// is what stops a dropped-entry note standing again if something later
    /// removes the entry that replaced it.
    public var abandonedPaths: [String]

    /// Every file whose **contents the pass did not read**, and why (slice 57b).
    ///
    /// The case it was built for is a cloud placeholder (`SF_DATALESS`): present,
    /// tracked and correctly sized — `st_size` is the file's true length, which is
    /// why the presence and size checks are still made on it — but hashing one
    /// *downloads* it. On a synced archive that turned this call into a
    /// whole-archive download, from a menu item that did not say so, ending in a
    /// report that claimed the archive was intact. (Measured afterwards: that
    /// state needs an archive kept as an ordinary directory. A `.genea` package on
    /// iCloud materializes whole, so nothing inside one is ever dataless — see
    /// `Archive.isDataless`.)
    ///
    /// **Every other way a file can go unread lands here too**, and that is the
    /// point rather than an extension of it: a read that fails, and a pass the
    /// user stopped, are both *files nobody looked at*. Before this list existed
    /// a failed hash was silently dropped — `try?` — so a file the pass could not
    /// read left a clean, complete report behind it (`/code-review`, 57b).
    ///
    /// **Beside `issues`, deliberately not among them**, for `abandonedPaths`'
    /// reason: not reading a file is not a finding about it. What must not happen
    /// is that it goes *unsaid* — see `isComplete`.
    public var notChecked: [NotCheckedFile]

    /// A file `verifyIntegrity()` did not read, why, and what reading it costs.
    ///
    /// **`byteLength` is the manifest's, not the disk's** — the archive already
    /// knows how big every tracked file is, so "41 files, 3.2 GB are not on this
    /// machine" is computable without reading a byte. A bare count is not a
    /// decision; the size is the half someone can decide from.
    public struct NotCheckedFile: Sendable, Equatable {
        /// Why the contents went unread. **Hosts must switch over this rather
        /// than assume the common case:** a row that says "it is present and the
        /// right size" is true of a placeholder and false of a file that could
        /// not be read, and the wrong one of those is a sentence the panel
        /// contradicts elsewhere on the same screen (`/code-review`, 57b).
        public enum Reason: Sendable, Equatable, CaseIterable {
            /// A cloud placeholder — the bytes are not on this machine, and
            /// reading them would download the file. The only reason a download
            /// resolves.
            case notOnThisMachine
            /// The read failed: an I/O error, a permission problem, or a download
            /// that did not complete on the opt-in path. Unlike the others this
            /// **is** a hint of something wrong; it is here rather than in
            /// `issues` because what it establishes is an absence of knowledge,
            /// not a fact about the contents.
            case couldNotRead
            /// The pass was cancelled before reaching this entry. Every remaining
            /// manifest entry is reported this way, so a stopped check describes
            /// itself exactly and can never read as a completed one.
            case checkWasStopped
        }

        public var path: String
        /// The manifest's recorded `byteLength` — what reading this file costs.
        public var byteLength: Int64
        public var reason: Reason

        public init(path: String, byteLength: Int64, reason: Reason) {
            self.path = path
            self.byteLength = byteLength
            self.reason = reason
        }
    }

    /// The bytes of everything that went unread.
    public var notCheckedByteCount: Int64 {
        notChecked.reduce(0) { $0 + $1.byteLength }
    }

    /// The entries a **download** would actually resolve, and their cost — what a
    /// host prices its "download and check the rest" action from.
    ///
    /// Deliberately not all of `notChecked`: downloading does nothing for a file
    /// that failed to read or for one the user stopped the pass before reaching,
    /// so quoting their bytes on that button would be quoting for work it will
    /// not do.
    public var downloadableNotChecked: [NotCheckedFile] {
        notChecked.filter { $0.reason == .notOnThisMachine }
    }

    /// What `downloadableNotChecked` would cost to fetch, in bytes.
    public var downloadableByteCount: Int64 {
        downloadableNotChecked.reduce(0) { $0 + $1.byteLength }
    }

    /// `true` when every tracked file's contents were actually read.
    ///
    /// **`isClean` is not enough, and this is the property that exists to say
    /// so.** `isClean` means *no problems were found*, which stays true when
    /// nothing was looked at — so the moment anything is skipped it silently
    /// stops meaning *verified*. Hosts must gate any sentence that claims
    /// verification (the app's *Archive Is Intact*) on `isClean && isComplete`;
    /// the same rule `FileSweepReport.foundNothingMissing` follows one tier down,
    /// where the answer was a property the false sentence cannot be written from.
    public var isComplete: Bool { notChecked.isEmpty }

    /// How many manifest entries the pass covered — every tracked file, whether
    /// or not its contents were read (`notChecked` names the ones that weren't,
    /// so *checked* is this minus that count).
    ///
    /// Reported so "no issues" can be told apart from "nothing to check". An
    /// archive last written before slice 49 carries no entries for its records,
    /// which is *unverified*, not *tampered* (spec §5) — a clean report over one
    /// entry reads exactly like a clean report over two hundred, and that
    /// ambiguity sent a hand-test looking for a bug that wasn't there.
    public var trackedFileCount: Int

    /// `true` when no problems were found.
    public var isClean: Bool { issues.isEmpty }

    /// The findings `Archive.rebaseline()` can actually resolve — a difference
    /// between a file's bytes and what the manifest recorded, on a file the
    /// manifest is the sole authority for.
    ///
    /// Hosts should gate their rebaseline affordance on this rather than on the
    /// issue kind (review finding, 49): a `.checksumMismatch` on an *attached*
    /// file is rot in a preservation master, which `rebaseline()` deliberately
    /// will not bless, so offering the button there is a scary confirmation
    /// followed by nothing changing. A missing or stray file is untouched by it
    /// either way.
    public var rebaselinableIssues: [Issue] {
        issues.filter(\.isResolvableByRebaseline)
    }

    public init(
        issues: [Issue] = [], trackedFileCount: Int = 0, abandonedPaths: [String] = [],
        notChecked: [NotCheckedFile] = []
    ) {
        self.issues = issues
        self.trackedFileCount = trackedFileCount
        self.abandonedPaths = abandonedPaths
        self.notChecked = notChecked
    }
}

extension IntegrityReport.Issue {
    /// The archive-relative path the finding concerns. Every case names one, and
    /// hosts key their rows on it.
    public var path: String {
        switch self {
        case .checksumMismatch(let path, _, _): path
        case .missingFile(let path): path
        case .sizeMismatch(let path, _, _): path
        case .unreferencedFile(let path): path
        case .interruptedWrite(let path): path
        case .awaitingDelivery(let path): path
        case .unreadableRecord(let path, _): path
        case .conflictingCopy(let path): path
        case .misnamedRecord(let path, _): path
        }
    }

    /// Whether `Archive.rebaseline()` would resolve this finding. See
    /// `IntegrityReport.rebaselinableIssues`.
    public var isResolvableByRebaseline: Bool {
        switch self {
        case .checksumMismatch(let path, _, _), .sizeMismatch(let path, _, _),
            .interruptedWrite(let path):
            ArchiveLayout.isEngineAuthored(relativePath: path)
        // A record whose file is gone is dropped from the manifest by a
        // rebaseline rather than reconciled — the rebuild it starts with takes
        // the record out of the index too. That is "the disk is the truth"
        // working as designed, but it is a deletion, not a repair, so it is not
        // something to offer as one.
        //
        // An unreadable record is the same answer for the opposite reason:
        // rebaseline blesses the bytes on disk, and these bytes are the problem.
        // Since 59 it does not even re-mint the entry — that entry is what proves
        // a restore from the preserved copy exact, so blessing bytes nothing can
        // read would destroy the one repair that *is* on offer. `repairRecord` is
        // the verb for this finding.
        // A delivery in flight must never offer a rebaseline: it would record
        // the stale local bytes as the truth and turn the incoming version into
        // a reported corruption. See `.awaitingDelivery`.
        //
        // A conflicting copy is outside the manifest entirely — nothing about it
        // is a difference between recorded and actual bytes — so there is nothing
        // for a rebaseline to bless, and the remedy is the user's: look at the
        // copy, then delete it.
        case .missingFile, .unreferencedFile, .unreadableRecord, .awaitingDelivery,
            .conflictingCopy, .misnamedRecord:
            false
        }
    }
}

// MARK: - DanglingReference

/// A conclusion record that points at something that no longer exists — the
/// residue the §2.3 **no-cascade** removals deliberately leave behind.
///
/// Removing a `Person`, an `Artifact` or a `PersonMention` never rewrites the
/// other records that referenced it: cascading would make the removal
/// irreversible (the app's undo restores the *exact* record it deleted, not a
/// fan-out of edits it also made) and would let one delete silently rewrite
/// conclusions the researcher never touched. The cost of that choice is stale
/// pointers, and this is the sweep that finds them — `findDanglingReferences()`.
///
/// Deliberately **separate from `IntegrityReport`**: that report answers "is the
/// BagIt-style evidence payload exactly what `manifest.json` says it is" and is
/// scoped to files (it explicitly does not audit `conclusions/` — see
/// `findUnreferencedFiles`). This one answers a *referential* question over the
/// conclusion records, costs no hashing, and is reported beside it rather than
/// folded into it.
///
/// Every case names the **holder** (the record that still exists and carries the
/// broken pointer — the thing a human would edit or delete to resolve it) first,
/// and the missing target second.
public enum DanglingReference: Sendable, Equatable, Hashable {
    /// A relationship endpoint (`person1Uid`/`person2Uid`) names a person that
    /// no longer exists. Both endpoints are reported when both are gone.
    case relationshipEndpoint(relationship: RelationshipID, missingPerson: PersonID)

    /// A relationship's `supportedByLinks` cites an evidence link that is gone.
    case relationshipSupport(relationship: RelationshipID, missingLink: EvidenceLinkID)

    /// A fact on a relationship (a couple's marriage/divorce — §4.5) cites an
    /// evidence link that is gone. `factIndex` addresses `Relationship.facts`.
    case relationshipFactSupport(
        relationship: RelationshipID, factIndex: Int, missingLink: EvidenceLinkID)

    /// A person fact cites an evidence link that is gone. `factIndex` addresses
    /// `Person.facts` (the same index the app's fact editor edits by).
    case personFactSupport(person: PersonID, factIndex: Int, missingLink: EvidenceLinkID)

    /// An evidence link's `artifactUid` names an artifact that is gone.
    case linkArtifact(link: EvidenceLinkID, missingArtifact: ArtifactID)

    /// An evidence link's `personUid` names a person that is gone.
    case linkPerson(link: EvidenceLinkID, missingPerson: PersonID)

    /// A relationship the **artifact itself states** between two of its mentions
    /// (§6.1's `mentionRelationships`, slice 45k) names a `localRef` the record no
    /// longer carries — the mention was removed and, as everywhere else, the removal
    /// did not cascade. `edgeIndex` addresses `Artifact.mentionRelationships`.
    ///
    /// The only finding here that lives in the **evidence** layer. It is reported in
    /// the same sweep anyway because the question is identical (does this pointer
    /// resolve?) and because a second, separately-invoked sweep is a sweep somebody
    /// forgets to run. Both endpoints are reported when both are gone.
    case mentionRelationshipEndpoint(artifact: ArtifactID, edgeIndex: Int, missingRef: String)

    /// A dismissal endpoint (§6.6, slice 45m) names a person that no longer exists.
    /// Both endpoints are reported when both are gone.
    ///
    /// A dangling dismissal is not inert: it still suppresses a suggestion, and the
    /// pair it suppresses can come back — `restorePerson` is one undo away, and 44g's
    /// repair path deletes records rather than resurrecting them. Left unfindable it
    /// would be a *no* nobody can see and nobody can retract.
    case dismissalEndpoint(dismissal: DismissalID, missingPerson: PersonID)

    /// An evidence link's `personMentionRef` no longer resolves: the artifact is
    /// **present** but carries no `PersonMention` with that `localRef` (the
    /// mention was removed while the citation survived). Reported only when the
    /// artifact itself exists — otherwise `linkArtifact` is the finding, and
    /// reporting both would double-count one broken link.
    case linkMention(link: EvidenceLinkID, artifact: ArtifactID, missingRef: String)
}
