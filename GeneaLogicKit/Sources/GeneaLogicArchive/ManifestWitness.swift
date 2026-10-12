import Foundation
import GeneaLogicModel

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// **What the index was built from** — a cheap, comparable summary of
/// `manifest.files` (slice 60, fork a).
///
/// The index has four rebuild triggers (missing, unopenable, schema-stale, and
/// 47's `.index/dirty` sentinel) and every one of them answers *is this database
/// usable?* None answers *does it reflect the files on disk?* So a `record.json`
/// that changed without this engine's involvement — delivered by cloud sync from
/// another machine, merged in by `git`, restored from a backup — leaves all four
/// satisfied and the index serving stale reads (ARCHITECTURE.md §10.4). This type is the missing
/// answer: the index records the witness it was built from, and a witness that
/// no longer matches the manifest means *rebuild*.
///
/// **What it does and does not cover.** It sees changes that arrive **with the
/// manifest that describes them** — a sync delivery from another machine, a
/// `git merge`, a restore from backup. It does **not** see a bare hand edit of
/// one `record.json`, which moves no manifest, and that exclusion is deliberate:
/// a file whose bytes disagree with the checksum the manifest recorded is
/// *suspect*, equally consistent with bit rot, so slice 49 reports it rather than
/// believing it and 58 refuses to overwrite it. Rebuilding the query surface from
/// it automatically would launder exactly what those two exist to catch. The
/// resolution there stays `rebaseline()`, which a human asks for.
///
/// **Why the manifest is a sufficient witness, and why that needed slice 49.**
/// Every table in the index derives from a file `manifest.files` now covers —
/// `artifact`/`place`/`file` from `artifacts/*/record.json` plus payload,
/// `person`/`relationship`/`link`/`dismissal` from `conclusions/**`,
/// `unreadable_record`/`orphaned_record` from the same walk. Before 49 the
/// sidecars and conclusions were deliberately *outside* the manifest, so a
/// `person add` changed the index and nothing else; folding their checksums in
/// is what makes the manifest move whenever anything the index derives from
/// moves. `ManifestWitnessTests` pins that claim table by table rather than
/// leaving it as prose.
///
/// **Why a content digest and not the alternatives** (fork a):
///
/// - **Not `manifest.updatedAt`.** It is `ISO8601DateFormatter` output at second
///   resolution, so two writes inside one second are indistinguishable.
/// - **Not the manifest file's own SHA-256.** That also moves when `name`
///   changes, which the index does not derive from — and a false positive here
///   costs a full rebuild.
/// - **Not a monotonic generation counter** (§10.4's option (b)). It needs a new
///   field in the format, and two machines bumping independently reach the same
///   value from different states — strictly *less* discriminating than a content
///   digest for the cross-machine case this exists for. Treat (b) as superseded,
///   not deferred.
///
/// **It is machine-local state, not format.** The witness is derived entirely
/// from data the format already carries; the only new thing on disk is the copy
/// the index keeps of its own, in `.index/`'s `meta` table — rebuildable and
/// outside the manifest, the integrity passes and the spec.
struct ManifestWitness: Equatable {
    /// SHA-256 over every entry's `path`, `sha256` and `byteLength`, in the
    /// manifest's own order.
    let digest: String

    /// `manifest.json`'s size and modification time when `digest` was taken —
    /// the cheap gate in front of it (fork c). `nil` when the file could not be
    /// `stat`ed, which reads as "no gate", never as "unchanged".
    let stamp: Stamp?

    /// A `stat(2)` of `manifest.json`, precise enough to be a gate.
    ///
    /// Nanosecond mtime rather than `Date`: a `Date` round-tripped through the
    /// `meta` table's text would compare unequal on its last digit and defeat
    /// the gate on every poll — the failure would be silent and would look like
    /// nothing more than the poll being slower than expected.
    struct Stamp: Equatable {
        let size: Int64
        let modifiedNanoseconds: Int64
    }

    /// Pairs a digest of `manifest` with a stamp **taken before `manifest` was
    /// read**.
    ///
    /// **The stamp must be the older of the two, and the parameter exists to make
    /// that impossible to get wrong** (`/code-review`, slice 60). An earlier
    /// version stamped the file itself, after digesting — so on the open path,
    /// where a full rebuild sits between the read and the stamp, a manifest
    /// delivered mid-rebuild got *stamped* but never *digested*. The cheap gate
    /// then reported "unchanged" against that newer stamp for ever, and the
    /// digest that would have caught it was never reached. Stamping first fails
    /// the other way: a manifest that changes after the stamp makes the next stat
    /// differ, which only costs a closer look.
    ///
    /// Use `read(from:)` rather than this wherever the manifest is being read for
    /// the purpose of comparing.
    static func of(_ manifest: Manifest, stampedBefore stamp: Stamp?) -> ManifestWitness {
        ManifestWitness(digest: digest(of: manifest), stamp: stamp)
    }

    /// Stamps, then reads, then digests — the ordering above, in one call, for
    /// callers that are reading the manifest in order to compare it.
    ///
    /// Returns `nil` if the manifest cannot be read or decoded. That is not
    /// evidence about staleness: callers treat it as "no information".
    static func read(from manifestURL: URL) -> ManifestWitness? {
        let stamp = stamp(of: manifestURL)
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? GeneaLogicJSONCoding.decoder.decode(Manifest.self, from: data)
        else { return nil }
        return of(manifest, stampedBefore: stamp)
    }

    /// The same, returning the entries it digested as well — for the one caller
    /// that must store both and cannot afford them to come from different reads
    /// (slice 60c; see `Archive.recordWitnessForFreshArchive`).
    static func readWithFiles(from manifestURL: URL) -> (ManifestWitness, [ManifestEntry])? {
        let stamp = stamp(of: manifestURL)
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? GeneaLogicJSONCoding.decoder.decode(Manifest.self, from: data)
        else { return nil }
        return (of(manifest, stampedBefore: stamp), manifest.files)
    }

    /// The digest alone — every entry's identity and measurements, joined in
    /// manifest order.
    ///
    /// Order is part of the digest deliberately: `recomputeManifestFiles` sorts
    /// by path on every commit, so two manifests that differ only in order do
    /// not arise from this engine, and treating one as a change costs a single
    /// rebuild in a case that means someone else wrote the file by hand.
    static func digest(of manifest: Manifest) -> String {
        var joined = ""
        for entry in manifest.files {
            joined += entry.path
            joined += "\u{1}"
            joined += entry.sha256
            joined += "\u{1}"
            joined += String(entry.byteLength)
            joined += "\u{2}"
        }
        return Checksum.sha256Hex(of: Data(joined.utf8))
    }

    /// `stat(2)` on `manifest.json`, or `nil` if it cannot be read.
    static func stamp(of manifestURL: URL) -> Stamp? {
        var st = stat()
        let ok = manifestURL.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &st) == 0 } ?? false
        }
        guard ok else { return nil }
        #if canImport(Darwin)
        let mtime = st.st_mtimespec
        #else
        let mtime = st.st_mtim
        #endif
        return Stamp(
            size: Int64(st.st_size),
            modifiedNanoseconds: Int64(mtime.tv_sec) * 1_000_000_000 + Int64(mtime.tv_nsec))
    }

    /// Whether two witnesses describe **the same set of files**, which is the
    /// only question a rebuild decision turns on.
    ///
    /// Deliberately not `==`: the stamp is a `stat` of `manifest.json` and moves
    /// whenever the file is rewritten, including when it is rewritten with
    /// identical contents (a `rebaseline` that changed nothing, a restore from a
    /// backup, a sync round-trip). Deciding on `==` would spend a full rebuild on
    /// each of those. The stamp's job is to let us *skip* the digest, never to
    /// stand in for it.
    func describesSameFiles(as other: ManifestWitness) -> Bool { digest == other.digest }

    /// Whether `manifestURL` is unchanged since this witness was taken, judged by
    /// the cheap stamp alone — one `stat(2)`, no read and no digest.
    ///
    /// **A missing stamp on either side answers `false`**, i.e. "look closer".
    /// The gate exists to skip work, so its only safe failure is to decline to
    /// skip it.
    func stampMatches(_ manifestURL: URL) -> Bool {
        guard let stamp, let current = Self.stamp(of: manifestURL) else { return false }
        return stamp == current
    }

    // MARK: - Storage

    /// The `meta`-table encoding: digest, size and mtime in one row, so reading
    /// or writing a witness is a single statement.
    var storedValue: String {
        guard let stamp else { return digest }
        return "\(digest) \(stamp.size) \(stamp.modifiedNanoseconds)"
    }

    /// Parses `storedValue`. Anything unparseable reads as `nil` — an absent
    /// witness, which callers treat as *unknown*, hence stale.
    init?(storedValue: String) {
        let parts = storedValue.split(separator: " ", omittingEmptySubsequences: false)
        guard let digest = parts.first, !digest.isEmpty else { return nil }
        self.digest = String(digest)
        if parts.count == 3, let size = Int64(parts[1]), let nanos = Int64(parts[2]) {
            self.stamp = Stamp(size: size, modifiedNanoseconds: nanos)
        } else {
            self.stamp = nil
        }
    }

    private init(digest: String, stamp: Stamp?) {
        self.digest = digest
        self.stamp = stamp
    }
}

/// What the index's recorded witness says about `manifest.json` as it is on disk
/// **right now** — the three answers a single `Bool` used to compress into two
/// (slice 60b).
///
/// The boolean it replaces was `recordedWitnessMatchesDisk()`, false both when
/// the witness *disagreed* with the disk and when there was **no witness at
/// all**, with every consumer reading that one value. Those two are not the same
/// claim: "the manifest is not the one I settled" is evidence a change arrived
/// from somewhere else, and "I have never looked" is evidence of nothing. Fusing
/// them let a first open of an archive with no `.index/` certify a delivery it
/// had only seen half of, after which `manifest.json` never changed again,
/// nothing re-fired, and `verifyIntegrity()` called the archive healthy while a
/// delivered record stayed invisible to every query.
///
/// **Deliberately one three-state value, not a second `Bool` beside the first.**
/// Two booleans admit a fourth combination that cannot occur, and the whole
/// defect was a value that could not express the case it was being asked about.
///
/// **Consumers must switch on it explicitly, and the grouping is asymmetric** —
/// see `Archive.deliveryIsInFlight` and `Archive.awaitedPaths(carriedFrom:)` for
/// the two directions and why `.unknown` goes a different way in each.
enum WitnessState: Equatable {
    /// There is a witness and it describes the manifest on disk. The index
    /// reflects the files; a mutation of ours may certify that it still does.
    case matches

    /// There is a witness and it describes a *different* manifest. Only a change
    /// from outside this engine can do that — corruption leaves `manifest.json`
    /// untouched — so this, and only this, is a delivery in flight.
    case disagrees

    /// **No witness at all** — an index written before slice 60, or one that has
    /// never settled a delivery. Stale, therefore worth a rebuild — but not
    /// evidence that anything arrived, and not evidence that anything is missing
    /// either.
    ///
    /// Strictly *no witness*, and not the wider "cannot tell right now": a
    /// manifest that is unreadable while a witness **is** recorded is
    /// `.disagrees`, because consumers of `.unknown` tell the user this archive
    /// has no history, which would then be false. See
    /// `Archive.witnessStateLocked()`.
    case unknown
}

/// **Which files the delivery now in flight actually covers** (slice 60c) — the
/// per-entry form of `Archive.deliveryIsInFlight`.
///
/// The flag it refines is archive-wide, and slice 60 said so in as many words:
/// it reports that *a* delivery is in flight, never which files it is bringing.
/// Every consumer that then relabelled a finding relabelled **all** of them, so
/// a file that had rotted months earlier was reported as *still arriving* for as
/// long as any unrelated delivery was in progress — `genea verify` told the user
/// to wait for a file that will never arrive, the standing damage banner went
/// quiet, and a dismissal they had already made was reset when it came back.
///
/// **The question that separates them.** With the entries of the last settled
/// manifest on hand, a mismatch on a path whose entry is *unchanged* since that
/// settling is damage: the manifest says exactly what it said when the index was
/// current, so nothing about this file is on its way. A mismatch on a path whose
/// entry *moved* — or that the settled manifest did not name at all — is the
/// delivery.
///
/// **Two empty cases, both deliberate:**
///
/// - **No delivery in flight** (`.matches`, and `.unknown` per 60b fork b):
///   nothing is covered, so every finding keeps its own name. That is the whole
///   of fork (c) — no history is not evidence of an arrival.
/// - **A delivery in flight with no settled entries**: an index written before
///   this slice, one whose rows could not be read, or a `manifest.json` that
///   does not currently decode — in which case the entries the delivery is
///   bringing are not visible to compare against at all (60b's outside writer,
///   caught mid-write). Everything reads as covered, which is slice 60's
///   behaviour exactly — the coarse answer, kept until the next settling records
///   the finer one, rather than a fresh accusation of damage made on evidence
///   this index does not hold.
struct DeliveryCoverage {
    /// `Archive.deliveryIsInFlight`, unchanged — the gate in front of every
    /// question below, and still what 61's window-wide bar asks.
    let isInFlight: Bool

    /// The last settled manifest's entries, keyed by path. Empty when nothing is
    /// in flight, since nothing then consults it.
    private let settled: [String: ManifestEntry]

    static let noDeliveryInFlight = DeliveryCoverage(isInFlight: false, settled: [:])

    /// A delivery in flight with nothing to say about which files it covers, so
    /// it covers all of them — slice 60's answer, kept for the two states that
    /// cannot do better (see the second empty case above).
    static let wholeArchive = DeliveryCoverage(isInFlight: true, settled: [:])

    init(isInFlight: Bool, settled: [String: ManifestEntry]) {
        self.isInFlight = isInFlight
        self.settled = settled
    }

    /// Whether a finding about `entry` belongs to the delivery rather than to
    /// damage — the test `verifyIntegrity()` and `sweepFileSizes()` make per file
    /// instead of consulting the archive-wide flag.
    func covers(_ entry: ManifestEntry) -> Bool {
        guard isInFlight else { return false }
        guard let settled = settled[entry.path] else { return true }
        return settled.sha256 != entry.sha256 || settled.byteLength != entry.byteLength
    }

    /// The same question from the drift guard, which holds a path and the hash
    /// the current manifest records for it (`authoredBaseline`) rather than a
    /// whole entry.
    ///
    /// The hash alone decides it: two contents that agree on SHA-256 and differ
    /// in length are not a case this engine has to distinguish.
    func covers(path: String, recordedSHA256: String) -> Bool {
        guard isInFlight else { return false }
        guard let settled = settled[path] else { return true }
        return settled.sha256 != recordedSHA256
    }

    /// The checksum `path` had when the index last settled — what bytes that
    /// have not moved since still hash to (slice 65). `nil` when nothing is in
    /// flight or the path was not settled.
    func settledSHA256(of path: String) -> String? {
        isInFlight ? settled[path]?.sha256 : nil
    }
}
