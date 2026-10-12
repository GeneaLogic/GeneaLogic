import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// `Archive.create`/`Archive.open` round-tripping, and the migration no-op path.
@Suite struct ArchiveLifecycleTests {

    @Test func createThenOpenRoundTrips() throws {
        let root = TestSupport.makeTempDirectory()

        let created = try Archive.create(at: root, name: "Smith Family Archive")
        let reopened = try Archive.open(at: root)

        // Both handles see the same persisted artifact set (empty, but the
        // manifest/identity must agree).
        #expect(created.artifacts().isEmpty)
        #expect(reopened.artifacts().isEmpty)

        let manifestURL = root.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: data)
        #expect(manifest.name == "Smith Family Archive")
        #expect(manifest.schemaVersion == SchemaVersion.current)
    }

    @Test func createFailsIfArchiveAlreadyExists() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root)

        #expect(throws: ArchiveError.alreadyExists(root)) {
            _ = try Archive.create(at: root)
        }
    }

    @Test func openFailsIfNoManifestPresent() throws {
        let root = TestSupport.makeTempDirectory()

        #expect(throws: ArchiveError.notAnArchive(root)) {
            _ = try Archive.open(at: root)
        }
    }

    @Test func openSurvivesAndReflectsPriorMutations() throws {
        let root = TestSupport.makeTempDirectory()

        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Marriage record"))

        let reopened = try Archive.open(at: root)
        let found = reopened.artifact(withID: artifact.uid)
        #expect(found?.title == "Marriage record")
        #expect(reopened.artifacts().count == 1)
    }

    // MARK: - Migration

    @Test func migrationIsNoOpForCurrentSchemaVersion() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root)

        let manifestURL = root.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)
        let beforeManifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: before)
        #expect(beforeManifest.schemaVersion == SchemaVersion.current)

        // Re-opening a current-version archive must not rewrite the manifest
        // (Migration.migrate returns `false` and `open` does not re-read it).
        let beforeUpdatedAt = beforeManifest.updatedAt
        _ = try Archive.open(at: root)

        let after = try Data(contentsOf: manifestURL)
        let afterManifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: after)
        #expect(afterManifest.updatedAt == beforeUpdatedAt)
        #expect(afterManifest.schemaVersion == SchemaVersion.current)
    }

    // MARK: - Regression: Bug 2 (create() must list the schema spec in the manifest)

    @Test func freshlyCreatedArchiveManifestListsSchemaSpec() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let manifestURL = root.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: data)

        let specEntry = manifest.files.first { $0.path.hasSuffix("genealogic-archive-1.0.md") }
        #expect(specEntry != nil, "manifest.files should list the bundled schema spec")

        if let specEntry {
            let specURL = root.appendingPathComponent(specEntry.path)
            #expect(FileManager.default.fileExists(atPath: specURL.path))
            let onDiskBytes = try Data(contentsOf: specURL)
            #expect(Int64(onDiskBytes.count) == specEntry.byteLength)
        }

        // Confirm the in-memory archive agrees (not just the file on disk).
        #expect(try archive.verifyIntegrity().isClean)
    }
}
