//
//  FileDamageSummary.swift
//  GeneaLogicApp
//

import Foundation
import GeneaLogicArchive

/// What the cheap sweep found, as the banner says it (slice 57).
///
/// **Failable on purpose: there is no value for a clean sweep.** The sweep has no
/// clean state — no banner, no "✓ 340 files checked" — because a cheap check that
/// implies an expensive check's assurance is worse than no check, and the surest
/// way not to write that sentence is to have nowhere to write it. So a report with
/// nothing in it produces no summary, and silence stays the only thing a healthy
/// archive says.
///
/// **The findings themselves get no hedging**, which is the inversion worth
/// keeping in mind here: this sweep's *positives* are certain — the manifest says
/// 700319 bytes and `stat` says 4096 is a fact, not an inference — and only its
/// silence is weak. So these strings are plain.
struct FileDamageSummary: Equatable {
    /// How many tracked files aren't there at all.
    let missingCount: Int
    /// How many are there but the wrong length.
    let wrongSizeCount: Int
    /// Every affected path, sorted — `pathSummary` decides how many are shown.
    let paths: [String]

    /// At most this many paths are named before the summary overflows to a count.
    /// Files have no browse list of their own, so the banner is the only place
    /// they are ever named (56's banner does the same for the record kinds with
    /// no list), and three is where naming stops helping and starts filling the
    /// window.
    static let maxNamedPaths = 3

    init?(_ report: Archive.FileSweepReport) {
        guard !report.foundNothingMissing else { return nil }

        var missing = 0
        var wrongSize = 0
        var paths: [String] = []
        for issue in report.issues {
            switch issue {
            case .missingFile(let path):
                missing += 1
                paths.append(path)
            case .sizeMismatch(let path, _, _):
                wrongSize += 1
                paths.append(path)
            case .awaitingDelivery:
                // **Counted by nothing, deliberately** (slice 60). The manifest is
                // ahead of the disk because a change is still arriving from
                // another machine — nothing is missing and nothing is damaged, and
                // this is the banner built specifically never to cry wolf. A large
                // preservation master syncing would otherwise put "1 file is
                // missing from this archive" on screen for the whole download.
                // The Verify panel still lists it, where there is room to say what
                // it means.
                continue
            default:
                // The sweep produces no other kind — it never reads a byte — and a
                // summary that quietly counted one would be claiming a check
                // nobody paid for.
                continue
            }
        }
        guard missing + wrongSize > 0 else { return nil }

        self.missingCount = missing
        self.wrongSizeCount = wrongSize
        self.paths = paths.sorted()
    }

    private init(missingCount: Int, wrongSizeCount: Int, paths: [String]) {
        self.missingCount = missingCount
        self.wrongSizeCount = wrongSizeCount
        self.paths = paths
    }

    /// `summary` with `missing` counted as missing files too — those it does not
    /// already name (slice 58d). The banner's records whose file is gone are
    /// standing findings, available before the first sweep finishes; once it has,
    /// it names every one of them itself and this changes nothing. `nil` only when
    /// both are empty — still no value for a clean archive.
    static func merging(_ summary: FileDamageSummary?, missing: [String]) -> FileDamageSummary? {
        let known = Set(summary?.paths ?? [])
        let extra = missing.filter { !known.contains($0) }
        guard !extra.isEmpty else { return summary }
        return FileDamageSummary(
            missingCount: (summary?.missingCount ?? 0) + extra.count,
            wrongSizeCount: summary?.wrongSizeCount ?? 0,
            paths: ((summary?.paths ?? []) + extra).sorted())
    }

    var totalCount: Int { missingCount + wrongSizeCount }

    /// The banner headline, in 56's voice — what happened, in the fewest words
    /// that stay true. The mixed case says "missing or the wrong size" rather than
    /// picking one, because either half alone would misdescribe some of the files
    /// it is counting.
    var headline: String {
        switch (missingCount, wrongSizeCount) {
        case (let missing, 0):
            return missing == 1
                ? "1 file is missing from this archive"
                : "\(missing) files are missing from this archive"
        case (0, let wrong):
            return wrong == 1
                ? "1 file is not the size the archive recorded"
                : "\(wrong) files are not the size the archive recorded"
        default:
            return "\(totalCount) files are missing or the wrong size"
        }
    }

    /// The files, named up to `maxNamedPaths` and then counted.
    ///
    /// **File names, not full paths** — a departure found by running the app.
    /// Archive paths repeat the artifact slug in the file name
    /// (`artifacts/deed-of-sale-jonasson-farmstead-1899/deed-of-sale-jonasson-farmstead-1899.tif`),
    /// so three of them wrapped to seven lines in a narrow window and the banner
    /// ate a third of it. The name is the identifying half and the folder it sits
    /// in is the half that was already redundant; `pathTooltip` still has the
    /// whole thing, and the banner is capped at two lines on top of this.
    ///
    /// **Except where that reasoning inverts** (review finding, 57): every
    /// artifact sidecar is `record.json`, so the folder is the *only* identifying
    /// half and two damaged records would read "record.json · record.json". Those
    /// are qualified with their folder — as is any other name that would collide
    /// with another in the same summary.
    var pathSummary: String {
        let shown = Array(paths.prefix(Self.maxNamedPaths))
        var counts: [String: Int] = [:]
        for path in shown { counts[Self.fileName(path), default: 0] += 1 }

        let named = shown.map { path -> String in
            let name = Self.fileName(path)
            let isAmbiguous = name == Self.recordFileName || (counts[name] ?? 0) > 1
            guard isAmbiguous else { return name }
            let folder = Self.fileName((path as NSString).deletingLastPathComponent)
            return folder.isEmpty ? name : "\(folder)/\(name)"
        }.joined(separator: " · ")

        let remaining = paths.count - shown.count
        return remaining > 0 ? "\(named) · …and \(remaining) more" : named
    }

    private static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The one file name reserved by convention (spec §2), spelled here because
    /// `ArchiveLayout` is internal to the engine — the same call `UnreadableRecordRow`
    /// makes when it parses a path into a row.
    private static let recordFileName = "record.json"

    /// Every affected path in full, one per line, for the banner's hover text —
    /// so shortening the visible line above loses nothing, it just stops the
    /// banner from becoming the list it was never meant to be.
    var pathTooltip: String { paths.joined(separator: "\n") }
}
