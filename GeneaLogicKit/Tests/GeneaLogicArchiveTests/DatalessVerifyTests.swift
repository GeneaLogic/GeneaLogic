#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicArchive

/// Slice 57b — `verifyIntegrity()` must not download the archive.
///
/// Hashing a cloud placeholder materializes it, so the hash pass over a synced
/// archive with un-downloaded preservation masters was a whole-archive download
/// wearing a menu item's clothes. It now skips those files, says which ones, and
/// refuses to call the result complete.
///
/// **Everything here runs through the injected placeholder test**, because
/// nothing in CI can make a real `SF_DATALESS` file — 57 established that by
/// measuring one by hand, and `nothingLocalIsDataless` is all a local archive can
/// hold. The signal in production is unchanged (`Archive.fileIsDataless(at:)`);
/// only the question is substituted, which is what turns skipped / checked /
/// opted-in / Linux-no-op from claims into tests.
@Suite struct DatalessVerifyTests {

    /// Two attached files on one artifact, so a test can call one of them a
    /// placeholder and leave the other genuinely local.
    private func archiveWithTwoFiles() throws -> (
        archive: Archive, cloud: (path: String, url: URL), local: (path: String, url: URL)
    ) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample())
        let slug = try #require(archive.artifacts().first?.slug)

        func attach(_ name: String, _ contents: String) throws -> (path: String, url: URL) {
            let source = try TestSupport.makeSourceFile(named: name, contents: contents)
            let attached = try archive.attachFile(
                copyingFrom: source, to: artifact.uid, role: .preservationMaster)
            let path = "artifacts/\(slug)/\(attached.entry.path)"
            return (path, root.appendingPathComponent(path))
        }

        return (archive, try attach("master.tif", "aaaaaaaa"), try attach("scan.tif", "bbbbbbbb"))
    }

    /// Rewrites a file's contents **keeping its length** — the damage only a hash
    /// can see, which is what makes "was this file read?" answerable at all.
    private func corruptKeepingSize(_ url: URL) throws {
        let size = try Data(contentsOf: url).count
        try Data(String(repeating: "z", count: size).utf8).write(to: url)
    }

    // MARK: - The skip

    /// The whole slice in one assertion: the placeholder's bytes are never read
    /// (its same-size corruption goes unreported, which is only possible if
    /// nothing hashed it), and it is named instead.
    @Test func aDatalessFileIsSkippedAndNamed() throws {
        let (archive, cloud, local) = try archiveWithTwoFiles()
        try corruptKeepingSize(cloud.url)

        let report = try archive.verifyIntegrity(
            includingDatalessFiles: false, isDataless: { $0.path == cloud.url.path })

        #expect(report.issues.isEmpty, "the placeholder was hashed: \(report.issues)")
        #expect(
            report.notChecked == [.init(path: cloud.path, byteLength: 8, reason: .notOnThisMachine)]
        )
        #expect(!report.isComplete)
        // Untouched by the skip — one file's placeholder status says nothing
        // about the next one's.
        #expect(FileManager.default.contents(atPath: local.url.path) == Data("bbbbbbbb".utf8))
    }

    /// The other side of the same walk: a file that *is* on this machine is
    /// hashed exactly as before, and is not listed as skipped.
    @Test func aMaterializedFileIsStillChecked() throws {
        let (archive, cloud, local) = try archiveWithTwoFiles()
        try corruptKeepingSize(local.url)

        let report = try archive.verifyIntegrity(
            includingDatalessFiles: false, isDataless: { $0.path == cloud.url.path })

        #expect(report.issues.count == 1)
        #expect(report.issues.first?.path == local.path)
        if case .checksumMismatch = report.issues.first {
        } else {
            Issue.record(
                "expected a checksum mismatch, got \(String(describing: report.issues.first))")
        }
        #expect(report.notChecked.map(\.path) == [cloud.path])
    }

    /// Opting in is the pre-57b behaviour, and the report says so: everything was
    /// read, so nothing is listed and the pass is complete.
    @Test func optingInHashesTheSkippedFileToo() throws {
        let (archive, cloud, _) = try archiveWithTwoFiles()
        try corruptKeepingSize(cloud.url)

        let report = try archive.verifyIntegrity(
            includingDatalessFiles: true, isDataless: { $0.path == cloud.url.path })

        #expect(report.issues.map(\.path) == [cloud.path])
        #expect(report.notChecked.isEmpty)
        #expect(report.isComplete)
    }

    // MARK: - What the report can and cannot claim

    /// `isClean` survives a skip — nothing was found because nothing was looked
    /// at — which is exactly why hosts cannot gate a verification claim on it.
    /// `isComplete` is false precisely when something was skipped.
    @Test func isCompleteIsFalseExactlyWhenSomethingWasSkipped() throws {
        let (archive, cloud, _) = try archiveWithTwoFiles()

        let skipped = try archive.verifyIntegrity(
            includingDatalessFiles: false, isDataless: { $0.path == cloud.url.path })
        #expect(skipped.isClean, "an undamaged archive is still clean")
        #expect(!skipped.isComplete, "but it was not verified")

        let full = try archive.verifyIntegrity(
            includingDatalessFiles: false, isDataless: { _ in false })
        #expect(full.isClean)
        #expect(full.isComplete)
    }

    /// The cost is the manifest's number, not the disk's — which is what makes it
    /// free to state. Held by giving the two different values: the file on disk is
    /// truncated, and the byte count still reports what downloading it would cost.
    ///
    /// It also pins the half of the check that is **not** skipped: a placeholder
    /// `stat`s to its true length (measured, 57), so a recorded size that no
    /// longer matches is damage and is still reported as damage.
    @Test func theCostComesFromTheManifestNotTheDisk() throws {
        let (archive, cloud, _) = try archiveWithTwoFiles()
        try Data("aa".utf8).write(to: cloud.url)

        let report = try archive.verifyIntegrity(
            includingDatalessFiles: false, isDataless: { $0.path == cloud.url.path })

        #expect(report.issues == [.sizeMismatch(path: cloud.path, expected: 8, actual: 2)])
        #expect(
            report.notChecked == [.init(path: cloud.path, byteLength: 8, reason: .notOnThisMachine)]
        )
        #expect(report.notCheckedByteCount == 8)
    }

    /// A file the manifest names but the disk does not have is missing, not
    /// skipped — the two must not be confused, since one is a fault and the other
    /// is a bill.
    @Test func aMissingFileIsNotASkippedOne() throws {
        let (archive, cloud, _) = try archiveWithTwoFiles()
        try FileManager.default.removeItem(at: cloud.url)

        let report = try archive.verifyIntegrity(
            includingDatalessFiles: false, isDataless: { $0.path == cloud.url.path })

        #expect(report.issues == [.missingFile(path: cloud.path)])
        #expect(report.notChecked.isEmpty)
        #expect(report.isComplete)
    }

    // MARK: - The other ways a file goes unread

    /// **An unopenable file must not hash as empty**, which is what it did: the
    /// stream reported its failure only through a status nobody read, the loop
    /// found no bytes, and `sha256Hex` returned the digest of *nothing* — a real
    /// hash, wrong, which every caller then compares against the manifest. So a
    /// file that could not be opened was reported as **corruption**, the one
    /// accusation the archive had no evidence for.
    ///
    /// Portable, unlike the permissions test below: no file can be opened at a
    /// path with nothing at it, whoever you are.
    @Test func anUnopenableFileThrowsRatherThanHashingEmpty() throws {
        let missing = TestSupport.makeTempDirectory().appendingPathComponent("gone.tif")
        let empty = TestSupport.makeTempDirectory().appendingPathComponent("empty.tif")
        try Data().write(to: empty)

        #expect(throws: (any Error).self) { try Checksum.sha256Hex(ofFileAt: missing) }
        // And a file that genuinely holds no bytes still hashes, since that is a
        // real answer about a real file — the two used to be indistinguishable.
        #expect(
            try Checksum.sha256Hex(ofFileAt: empty)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// **A read that fails must not vanish** (`/code-review`). It was a `try?`,
    /// so a file the pass could not read contributed nothing at all: clean, and
    /// *complete*, over a file nobody had read — the exact claim this slice
    /// exists to prevent, reachable on the opt-in path where a download can fail.
    ///
    /// **Skipped as root**, which is how the Linux container runs: mode 0 does
    /// not stop root reading, so there the archive is simply checked and the
    /// premise is gone. The property is the engine's, not the platform's, and it
    /// is held on every ordinary machine — including CI's macOS job.
    @Test(
        .enabled(
            if: getuid() != 0, "mode 0 does not stop root, and the Linux container runs as root"))
    func aFileThatCannotBeReadIsReportedAsUnread() throws {
        let (archive, cloud, _) = try archiveWithTwoFiles()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloud.url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: cloud.url.path)
        }

        let report = try archive.verifyIntegrity(
            includingDatalessFiles: true, isDataless: { _ in false })

        #expect(
            report.notChecked == [.init(path: cloud.path, byteLength: 8, reason: .couldNotRead)])
        #expect(!report.isComplete, "a file nobody could read is not a verified file")
        #expect(report.issues.isEmpty, "an unread file is an absence of knowledge, not a finding")
    }

    /// A read error is not a download: offering to fetch it would be offering
    /// work that cannot help.
    @Test func aFailedReadIsNotPricedAsADownload() {
        let report = IntegrityReport(
            trackedFileCount: 2,
            notChecked: [
                .init(path: "a.tif", byteLength: 100, reason: .couldNotRead),
                .init(path: "b.tif", byteLength: 8, reason: .notOnThisMachine),
            ])

        #expect(report.notCheckedByteCount == 108)
        #expect(report.downloadableNotChecked.map(\.path) == ["b.tif"])
        #expect(report.downloadableByteCount == 8)
    }

    // MARK: - Stopping it

    /// **A stopped pass describes itself exactly**: every entry it never reached
    /// comes back unread, so `isComplete` is false and no surface can render a
    /// cancelled check as a finished one. Without this, cancelling produced a
    /// report over a *prefix* of the archive that claimed to cover all of it.
    @Test func aCancelledPassReportsEverythingItDidNotRead() async throws {
        let (archive, _, _) = try archiveWithTwoFiles()
        let tracked = try archive.verifyIntegrity().trackedFileCount

        let task = Task { try archive.verifyIntegrity() }
        task.cancel()
        let report = try await task.value

        #expect(!report.isComplete)
        #expect(report.notChecked.count == tracked, "every entry should be reported unread")
        #expect(report.notChecked.allSatisfy { $0.reason == .checkWasStopped })
        #expect(report.isClean, "stopping a check is not a finding about the archive")
    }

    /// And an uncancelled pass is unaffected — a check is a check, not a
    /// coin-toss on task state.
    @Test func anUncancelledPassIsUnaffected() async throws {
        let (archive, _, _) = try archiveWithTwoFiles()
        let report = try await Task { try archive.verifyIntegrity() }.value

        #expect(report.isClean)
        #expect(report.isComplete)
    }

    // MARK: - The cross-platform contract

    /// **The behaviour that keeps Linux byte-identical**, run on both platforms
    /// against the real signal: an ordinary local archive has no placeholders, so
    /// the default call skips nothing and the report is complete. Off Darwin
    /// `Archive.isDataless` is `false` by construction rather than by `#if` in the
    /// walk, which is what makes this the same test on both.
    @Test func nothingIsSkippedWithoutAPlaceholder() throws {
        let (archive, _, _) = try archiveWithTwoFiles()

        let report = try archive.verifyIntegrity()
        #expect(report.isClean)
        #expect(report.isComplete)
        #expect(report.notChecked.isEmpty)
        #expect(report.notCheckedByteCount == 0)
    }
}
