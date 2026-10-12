import Foundation
import GeneaLogicModel

/// Which file on disk **is** a record, when more than one claims to be
/// (slice 50c).
///
/// A sync provider that cannot merge one file leaves a second copy of it beside
/// the first — Dropbox writes `X (Ada's conflicted copy 2026-08-29).json`,
/// iCloud writes `X 2.json`. Two of the engine's discovery walks used to be
/// name-blind, so the copy was loaded into the index alongside the original,
/// which of the two won was `contentsOfDirectory` order, and the next ordinary
/// mutation wrote the winner's contents back into the canonical sidecar. That is
/// silent data loss through the normal path, and it is what these rules stop.
///
/// **Decided on structure, never on the provider's naming** (slice 50c, fork d).
/// `(conflicted copy` and ` 2.json` are provider-specific, localizable and
/// brittle; *one uid, one file* is the archive's own invariant, holds whatever
/// wrote the copy, and catches a plain `cp` too. The provider's naming may be
/// used to *word* a finding, never to make one.
///
/// Both consumers apply the rules here so they cannot drift apart:
/// `ArchiveIndex.rebuild(walking:manifestRecordPaths:)` declines to load a copy,
/// and `Archive.verifyIntegrity()` reports it.
enum RecordDiscovery {

    /// Whether `url` is the file that *is* the conclusion record it decoded to.
    ///
    /// The engine writes every conclusion as `conclusions/<kind>/<uid>.json` and
    /// `Archive.authoredPaths` names exactly that path in the manifest, so the
    /// canonical name already exists — nothing enforced it. Anything else in the
    /// directory is a copy: not loaded, and reported.
    ///
    /// **Both halves are checked** — the name must be `<uid>.json` *and* the uid
    /// inside must be the one the name spells. The first half is what a sync
    /// provider trips; the second is what a copy renamed to a plausible-looking
    /// uid trips, and leaving it out would make the rule enforceable by renaming
    /// a file.
    static func isCanonicalConclusionFile(_ url: URL, uid: String) -> Bool {
        url.lastPathComponent == "\(uid).json"
    }

    /// The folder that *is* the artifact, when two under `artifacts/` decode to
    /// one `ART-…` (slice 50c, fork e).
    ///
    /// Slugs are non-authoritative friendly names and renaming a folder is
    /// legitimate (§4.2.1), so the *name* cannot decide this. **The manifest's
    /// incumbent does:** an entry for `artifacts/<slug>/record.json` predates the
    /// copy, because the copy has never been through a commit. Where the manifest
    /// names neither — an artifact that arrived together with its copy in one
    /// sync — or both, the lexicographically first path wins: arbitrary, but
    /// stable across machines and independent of enumeration order, which is what
    /// keeps two machines from disagreeing about which one is the record.
    ///
    /// **The fallback compares the folder, not the whole path, and that is not a
    /// detail** (`/code-review`, 50c). Comparing `artifacts/portrait/record.json`
    /// against `artifacts/portrait 2/record.json` puts the separator `/` (0x2F)
    /// against a space (0x20) — and `(` is 0x28 — so on the full path the copy
    /// sorts *first* and wins, deterministically, under both providers' naming.
    /// That is the opposite of arbitrary: with no incumbent (a pre-slice-49
    /// manifest that names no records, or an artifact that arrived together with
    /// its copy) the record would have become the copy, and the genuine folder's
    /// preservation masters would have lost their manifest coverage with the
    /// switch. Compared at the folder, the original is a strict prefix of every
    /// name a provider derives from it, so it sorts first.
    ///
    /// A pairwise reduction gives the same answer as one call over every
    /// candidate — the preference is a per-element predicate and `min` is
    /// associative — which is what lets `rebuild` decide as it walks instead of
    /// holding every artifact in memory first.
    ///
    /// - Parameters:
    ///   - candidates: Archive-relative `record.json` paths, in any order.
    ///   - incumbents: The `record.json` paths the manifest already names.
    static func chooseArtifactRecord(
        from candidates: [String], incumbents: Set<String>
    ) -> String? {
        let preferred = candidates.filter(incumbents.contains)
        return (preferred.isEmpty ? candidates : preferred).min {
            artifactFolder(ofRecordAt: $0) < artifactFolder(ofRecordAt: $1)
        }
    }

    /// `artifacts/<slug>/record.json` → `artifacts/<slug>`. The comparison key
    /// for the tie-break above; every candidate is a `record.json`, and the
    /// suffix is dropped defensively rather than assumed.
    private static func artifactFolder(ofRecordAt path: String) -> String {
        let suffix = "/\(ArchiveLayout.recordFileName)"
        return path.hasSuffix(suffix) ? String(path.dropLast(suffix.count)) : path
    }

    /// The record paths a manifest names — every `artifacts/<slug>/record.json`
    /// and every `conclusions/…` file. The artifact ones are the incumbents
    /// `chooseArtifactRecord(from:incumbents:)` prefers (it only ever asks about
    /// those); the whole set is what `ArchiveIndex.rebuild` tells a *deleted*
    /// record from a lost one by (slice 58c).
    ///
    /// Exactly `ArchiveLayout.isEngineAuthored` — the set the manifest recompute
    /// carries and `rebaseline()` re-mints — so the prune's keep-set cannot drift
    /// from what the rest of the engine calls a record.
    static func recordPaths(in manifest: Manifest) -> Set<String> {
        Set(
            manifest.files.lazy.map(\.path).filter {
                ArchiveLayout.isEngineAuthored(relativePath: $0)
            })
    }
}
