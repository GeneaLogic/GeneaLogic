import ArgumentParser
import Foundation
import GeneaLogicArchive

/// The shape every archive-scoped subcommand shares: take an archive path, open
/// it, do one thing, render the result.
///
/// Without this, each command spells out the same
/// `URL(fileURLWithPath:) → Archive.open → do/catch → ExitCode` dance around its
/// one interesting line — which was tolerable at eight commands and is not at
/// twenty-three. Conforming leaves a command as just its `run(archive:…)` body,
/// while keeping the **same** testable entry point (`run(stdout:stderr:)`) the
/// tests drive, so this is a factoring rather than a new architecture.
///
/// Errors follow the established contract (`CLIError`): `ArchiveError` renders
/// its human-readable `description`, anything else falls back to
/// `String(describing:)`, and every failure exits non-zero.
///
/// **Two design points, both forced by real commands:**
///
/// - **`stderr` is passed to every command**, not just the ones that use it.
///   Most write nothing there, but `attach` reports a non-fatal
///   "byte-identical content already attached" note, and a command that can't
///   reach stderr would have to either drop that or opt out of the protocol
///   entirely. One uniform signature beats a second protocol for one case.
/// - **A deliberately-thrown `ExitCode` passes through untouched.** `verify`'s
///   contract is "the run succeeded, and the report is not clean" — a non-zero
///   exit that is *not* an error. Feeding that through `CLIError.report` would
///   print a nonsense `Error: ExitCode(rawValue: 1)` line to stderr, so the
///   catch distinguishes an exit code from a failure.
protocol ArchiveSubcommand: ParsableCommand {
    /// The archive path (declared as an `@Argument` by each conforming command).
    var archive: String { get }

    /// The command's actual work, against an already-opened archive.
    func run(archive: Archive, stdout: CLIOutput, stderr: CLIOutput) throws
}

extension ArchiveSubcommand {
    func run() throws {
        try run(stdout: StandardOutput.out, stderr: StandardOutput.err)
    }

    func run(stdout: CLIOutput, stderr: CLIOutput) throws {
        let archiveURL = URL(fileURLWithPath: archive, isDirectory: true)
        announceMachineKeyOverrideIfSet(to: stderr)
        do {
            let opened = try Archive.open(at: archiveURL)
            try run(archive: opened, stdout: stdout, stderr: stderr)
        } catch let exitCode as ExitCode {
            // A chosen exit status, not a failure — see the note above.
            throw exitCode
        } catch {
            throw ExitCode(rawValue: CLIError.report(error, to: stderr).rawValue)
        }
    }

    /// Says so, once per invocation, when this process's `.index/<machine-key>/`
    /// was chosen by anything other than the stable derivation (slice 48).
    ///
    /// Both cases share one failure mode — **silence**. A stale `export` of the
    /// testing seam, or a boot-volume UUID this process could not read while
    /// another process could, leaves this `genea` on a different **lockfile**
    /// from the app: 47's mutual exclusion stops excluding with no symptom until
    /// two writes collide, which is the one thing per-machine indexes must not
    /// cost. A key that announces where it came from is diagnosable; one that
    /// does not looks like the engine losing a write.
    private func announceMachineKeyOverrideIfSet(to stderr: CLIOutput) {
        switch MachineKey.derivation {
        case .override:
            stderr.writeLine(
                "note: \(MachineKey.overrideEnvironmentVariable) is set — "
                    + "using .index/\(MachineKey.current)/")
        case .hostName:
            stderr.writeLine(
                "note: no stable machine identifier was readable, so this archive's index "
                    + "key comes from the hostname — using .index/\(MachineKey.current)/. "
                    + "A hostname change starts a new index.")
        case .volumeUUID, .machineID:
            break
        }
    }
}
