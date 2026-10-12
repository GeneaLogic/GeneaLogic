import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// `verifyIntegrity()` / `repair()` (ARCHITECTURE.md §3, §6.3).
@Suite struct IntegrityTests {

    @Test func cleanArchiveReportsNoIssues() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Pristine"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "untouched bytes")
        try archive.attachFile(copyingFrom: source, to: artifact.uid, role: .preservationMaster)

        let report = try archive.verifyIntegrity()
        #expect(report.isClean)
        #expect(report.issues.isEmpty)
    }

    @Test func tamperedByteIsReportedAsChecksumMismatch() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Tampered"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "original bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)

        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")
        try Data("TAMPERED bytes!!".utf8).write(to: onDisk)

        let report = try archive.verifyIntegrity()
        #expect(!report.isClean)

        let relativePath = "artifacts/\(slug)/\(attached.entry.path)"
        let mismatch = report.issues.first {
            if case .checksumMismatch(let path, _, _) = $0 { return path == relativePath }
            return false
        }
        #expect(mismatch != nil)
    }

    @Test func deletedFileIsReportedAsMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Vanishing"))
        let source = try TestSupport.makeSourceFile(named: "doc.pdf", contents: "important record")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)

        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")
        try FileManager.default.removeItem(at: onDisk)

        let report = try archive.verifyIntegrity()
        #expect(!report.isClean)

        let relativePath = "artifacts/\(slug)/\(attached.entry.path)"
        let missing = report.issues.first {
            if case .missingFile(let path) = $0 { return path == relativePath }
            return false
        }
        #expect(missing != nil)
    }

    @Test func strayFileInArtifactFolderIsReportedAsUnreferenced() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Has a stowaway"))
        let source = try TestSupport.makeSourceFile(named: "known.txt", contents: "tracked")
        try archive.attachFile(copyingFrom: source, to: artifact.uid, role: .accessCopy)

        let slug = try #require(archive.artifacts().first?.slug)
        let strayURL = root.appendingPathComponent("artifacts/\(slug)/uninvited.txt")
        try Data("nobody told the engine about me".utf8).write(to: strayURL)

        let report = try archive.verifyIntegrity()
        #expect(!report.isClean)

        let relativePath = "artifacts/\(slug)/uninvited.txt"
        let unreferenced = report.issues.first {
            if case .unreferencedFile(let path) = $0 { return path == relativePath }
            return false
        }
        #expect(unreferenced != nil)

        // And nothing else got swept up as a false positive: record.json, the
        // known attached file, manifest.json, and the schema spec must all be
        // silent.
        let falsePositivePaths: [String] = [
            "artifacts/\(slug)/record.json",
            "manifest.json",
        ]
        for issue in report.issues {
            if case .unreferencedFile(let path) = issue {
                #expect(!falsePositivePaths.contains(path), "false positive: \(path)")
                #expect(!path.hasPrefix("conclusions/"), "conclusions must be exempt: \(path)")
                #expect(!path.hasPrefix(".index/"), ".index must be exempt: \(path)")
                #expect(
                    !path.hasSuffix("genealogic-archive-1.0.md"),
                    "the schema spec must be exempt: \(path)")
            }
        }
    }

    @Test func sizeMismatchIsDetectedIndependentlyOfChecksum() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Truncated"))
        let source = try TestSupport.makeSourceFile(
            named: "long.txt", contents: "this content is reasonably long for a truncation test")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .accessCopy)

        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")
        // Truncate to a different length (also changes the checksum, but the
        // size check must independently fire — see the doc comment on
        // `IntegrityReport.Issue.sizeMismatch`).
        try Data("short".utf8).write(to: onDisk)

        let report = try archive.verifyIntegrity()
        let relativePath = "artifacts/\(slug)/\(attached.entry.path)"
        let sizeIssue = report.issues.first {
            if case .sizeMismatch(let path, _, _) = $0 { return path == relativePath }
            return false
        }
        #expect(sizeIssue != nil)
    }

    @Test func repairIsAnHonestStub() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        #expect(throws: ArchiveError.repairNotImplemented) {
            try archive.repair()
        }
    }
}
