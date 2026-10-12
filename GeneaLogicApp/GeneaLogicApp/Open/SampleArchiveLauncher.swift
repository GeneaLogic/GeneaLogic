import Foundation
import GeneaLogicSample

/// The welcome screen's sample archive (slice 74b): one copy in the app's own
/// Application Support, built the first time it is asked for and opened as it stands
/// after that, edits and all. Nothing is written to the user's folders, and it lands in
/// Recent like any archive, where *Show in Finder* finds it. Starting over is deleting it.
nonisolated enum SampleArchiveLauncher {
    /// `Application Support/Sample/Hanner Family Sample.genea`. In the sandbox that is
    /// inside the app's container.
    static func defaultLocation() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        return support.appendingPathComponent("Sample", isDirectory: true)
            .appendingPathComponent(SampleArchive.fileName, isDirectory: true)
    }

    /// The sample at `url`, built first if nothing is there. Slow enough (about half a
    /// second) to keep off the main actor.
    static func prepare(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try SampleArchive.build(at: url)
        } catch SampleArchiveError.alreadyExists {
            // Built on an earlier click, or by another window during this one; either way,
            // what is there is the sample.
        }
        return url
    }
}
