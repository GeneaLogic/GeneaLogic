import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 47 — the multi-process half, and the reason it lives in the *CLI*
/// package: the honest test of cross-process write safety cannot run in-process.
/// `ArchiveLock` is an `flock(2)` on `.index/lock`, so proving it works means
/// running real, separate `genea` invocations against one archive at once —
/// which needs the built binary, which only this package has.
///
/// The engine-side unit tests (`GeneaLogicArchiveTests/
/// CrossProcessWriteSafetyTests.swift`) pin the mechanism; these pin the
/// outcome.
@Suite struct ConcurrentWriterTests {

    /// The number of simultaneous writers. Chosen to comfortably exceed the
    /// contention needed to reproduce the old failure (which needed only two)
    /// while keeping the suite fast — each invocation is a process launch, and
    /// launch dominates the milliseconds of actual mutation.
    static let writerCount = 8

    /// Eight `genea add` processes against one archive, started together.
    ///
    /// Before this slice every one of them was a coin flip: the losers of the
    /// SQLite race threw on `SQLITE_BUSY` immediately, and any that got past it
    /// could still lose a sidecar to a concurrent write. The assertion is
    /// therefore the blunt one — **every** writer's artifact is present, none
    /// was displaced.
    @Test func eightConcurrentAddsAllLand() throws {
        let root = try makeArchive()

        let results = try runConcurrently(
            (0..<Self.writerCount).map { index in
                ["add", root.path, "--title", "Artifact \(index)", "--media-type", "document"]
            })

        for result in results {
            #expect(result.status == 0, "genea add failed (\(result.status)): \(result.stderr)")
        }

        let archive = try Archive.open(at: root)
        let titles = Set(archive.artifacts().map(\.title))
        #expect(titles == Set((0..<Self.writerCount).map { "Artifact \($0)" }))
    }

    /// The same race across *different* record types, so the writers contend on
    /// the archive lock and the manifest without contending on the same table.
    /// A per-artifact lock would have let these through while still corrupting
    /// the manifest they all rewrite — which is fork (b)'s whole argument for
    /// locking the archive rather than the record.
    @Test func concurrentWritersOfDifferentRecordTypesAllLand() throws {
        let root = try makeArchive()

        let invocations =
            (0..<4).map { index in
                ["add", root.path, "--title", "Artifact \(index)"]
            }
            + (0..<4).map { index in
                ["person", "add", root.path, "--given", "Person\(index)", "--surname", "Test"]
            }

        let results = try runConcurrently(invocations)
        for result in results {
            #expect(result.status == 0, "genea failed (\(result.status)): \(result.stderr)")
        }

        let archive = try Archive.open(at: root)
        #expect(archive.artifacts().count == 4)
        #expect(archive.persons().count == 4)
    }

    /// **The invariant that actually matters.** The sidecars are authoritative
    /// and the index is a rebuildable cache, so the real contract after any
    /// interleaving is: every sidecar still parses, and `rebuildIndex()` — a
    /// full re-walk of those sidecars — reproduces exactly what the index
    /// already held. If a concurrent write had torn a sidecar or skipped an
    /// index upsert, the two would differ.
    ///
    /// This is a stronger check than any per-operation assertion, because it
    /// does not depend on knowing which operations raced.
    @Test func theIndexStillMatchesTheSidecarsAfterAConcurrentBurst() throws {
        let root = try makeArchive()

        let results = try runConcurrently(
            (0..<Self.writerCount).map { index in
                index.isMultiple(of: 2)
                    ? ["add", root.path, "--title", "Artifact \(index)", "--tag", "burst"]
                    : ["person", "add", root.path, "--given", "Person\(index)"]
            })
        for result in results {
            #expect(result.status == 0, "genea failed (\(result.status)): \(result.stderr)")
        }

        let archive = try Archive.open(at: root)
        let artifactsBefore = archive.artifacts().map(\.uid).sorted { $0.raw < $1.raw }
        let personsBefore = archive.persons().map(\.uid).sorted { $0.raw < $1.raw }
        #expect(artifactsBefore.count == 4)
        #expect(personsBefore.count == 4)

        try archive.rebuildIndex()

        #expect(archive.artifacts().map(\.uid).sorted { $0.raw < $1.raw } == artifactsBefore)
        #expect(archive.persons().map(\.uid).sorted { $0.raw < $1.raw } == personsBefore)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// A writer must not leave the dirty sentinel behind on the way out —
    /// otherwise every open after a normal burst would pay for a full rebuild,
    /// and the sentinel would stop meaning anything.
    @Test func aConcurrentBurstLeavesNoDirtySentinel() throws {
        let root = try makeArchive()

        let results = try runConcurrently(
            (0..<Self.writerCount).map { index in
                ["add", root.path, "--title", "Artifact \(index)"]
            })
        // Asserted alongside the sentinel on purpose: a burst where writers
        // *failed* would also often end clean (the last one out clears the
        // marker), so "no sentinel" only means something if everyone succeeded.
        #expect(results.allSatisfy { $0.status == 0 })

        let sentinel = root.appendingPathComponent(".index/\(MachineKey.current)/dirty")
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    /// **Review regression (47).** `Archive.create` used to run its
    /// `alreadyExists` guard and write `manifest.json` *before* a lockfile
    /// existed — the one mutation outside "one writer at a time, machine-wide".
    /// Concurrent creates therefore all passed the guard, and the last one to
    /// finish silently overwrote the others' `archiveUID`: a brand-new archive
    /// whose identity was decided by a race.
    ///
    /// Multi-process by necessity — the in-process test can only check that the
    /// guard still rejects a *sequential* second create, which it did before the
    /// fix too.
    @Test func concurrentCreatesProduceExactlyOneArchive() throws {
        let root = TestSupport.makeTempDirectory().appendingPathComponent("Contested.genea")

        let results = try runConcurrently(
            (0..<6).map { index in ["create", root.path, "--name", "Creator \(index)"] })

        let succeeded = results.filter { $0.status == 0 }
        #expect(succeeded.count == 1, "expected exactly one winner, got \(succeeded.count)")

        // Every loser must have been *told*, not silently ignored.
        for loser in results where loser.status != 0 {
            #expect(
                loser.stderr.contains("already exists"),
                "a losing create should report the collision, said: \(loser.stderr)")
        }

        // And the winner's archive is intact and usable — one identity, one name.
        let archive = try Archive.open(at: root)
        #expect(try archive.verifyIntegrity().isClean)
        #expect(archive.artifacts().isEmpty)
    }

    // MARK: - Running the real binary

    struct InvocationResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Launches every invocation, *then* waits — so they genuinely overlap.
    /// Launching and waiting one at a time would test nothing.
    private func runConcurrently(_ invocations: [[String]]) throws -> [InvocationResult] {
        let binary = try Self.geneaBinary()

        let processes: [(Process, Pipe, Pipe)] = try invocations.map { arguments in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            return (process, out, err)
        }

        return processes.map { process, out, err in
            // Read before waiting: a writer that fills the 64 KB pipe buffer
            // would otherwise block forever on a `waitUntilExit` that never
            // drains it. Output here is tiny, but the deadlock is silent and the
            // fix is free.
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return InvocationResult(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self))
        }
    }

    private func makeArchive() throws -> URL {
        let root = TestSupport.makeTempDirectory().appendingPathComponent("Concurrent.genea")
        _ = try Archive.create(at: root, name: "Concurrent")
        return root
    }

    /// The `genea` executable this package just built.
    ///
    /// It always sits in SwiftPM's products directory — the same one holding the
    /// test bundle — but *how you find that directory* differs by platform and
    /// even by test runner: on macOS the swift-testing helper is the running
    /// executable and the bundle path arrives in argv, while on Linux the test
    /// binary is `Bundle.main`. Rather than encode one of those, collect every
    /// plausible directory and pick the one that actually has `genea` in it.
    /// Hardcoding `.build/debug` would break under `--scratch-path`,
    /// `-c release`, and CI alike.
    private static func geneaBinary() throws -> URL {
        var candidates: [URL] = [Bundle.main.bundleURL]
        candidates += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        for argument in ProcessInfo.processInfo.arguments where argument.contains("/.build/") {
            var url = URL(fileURLWithPath: argument)
            for _ in 0..<4 {
                url = url.deletingLastPathComponent()
                candidates.append(url)
            }
        }

        for directory in candidates {
            let binary = directory.appendingPathComponent("genea")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return binary
            }
        }
        throw CLITestError(
            "No `genea` executable in any of: \(candidates.map(\.path).joined(separator: ", "))")
    }

    struct CLITestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
