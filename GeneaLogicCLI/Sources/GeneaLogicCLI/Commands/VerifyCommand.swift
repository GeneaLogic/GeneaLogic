import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea verify <archive>` → `verifyIntegrity()` + `findDanglingReferences()`.
///
/// **Two sweeps, two registers.** File integrity (`verifyIntegrity()`) answers
/// "is the evidence payload exactly what `manifest.json` says" — corruption, and
/// what drives the exit code. Reference integrity (`findDanglingReferences()`,
/// slice 44e) answers "does every conclusion point at a record that still exists"
/// — the residue §2.3 no-cascade removals deliberately leave, reported
/// **informationally**: it never changes the exit. So a removed person whose
/// relationships you haven't cleaned up yet shows up here, but doesn't make CI red
/// the way real corruption does.
///
/// **Exit-code contract (load-bearing for CI/scripts):** if
/// `IntegrityReport.isClean` is `false`, the command throws `ExitCode.failure` —
/// the *one* place a successful (non-throwing) engine call still produces a
/// non-zero exit, by design, so `genea verify <archive> || alert` /
/// `if ! genea verify …` works without the caller having to parse output.
/// Dangling references never trip it.
///
/// That contract is why `ArchiveSubcommand`'s wrapper passes a thrown `ExitCode`
/// through untouched instead of running it through `CLIError.report` — a chosen
/// exit status is not a failure, and reporting it would print a nonsense
/// `Error: ExitCode(rawValue: 1)` line after a perfectly good report.
///
/// **Files that are not downloaded to this machine are not read** (slice 57b),
/// and `--download-cloud-files` is the opt-in that pays for them. They are
/// reported as a note, and **never** change the exit: a file the engine declined
/// to download is not a problem with the archive, and failing on one would make
/// every synced archive red. What the note protects is the *other* sentence — a
/// report that skipped half the payload must not print as a full verification,
/// which is why the clean line says PARTIAL and names the count instead.
struct VerifyCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify archive integrity; exits non-zero on file-integrity problems."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Flag(
        name: .customLong("download-cloud-files"),
        help: ArgumentHelp(
            "Also check files that aren't downloaded to this machine. Reading one downloads "
                + "it, so this can pull the whole archive down; without it those files are "
                + "listed as not checked."))
    var downloadCloudFiles = false

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let report = try opened.verifyIntegrity(includingDatalessFiles: downloadCloudFiles)
        let dangling = opened.findDanglingReferences()

        if report.isClean {
            stdout.writeLine(Self.cleanLine(report))
        } else {
            // An unreadable record's line says whether `genea repair` has anything
            // for it (slice 59), and so does a missing one's (58d) — a record whose
            // file vanished keeps its copy too. Telling every damaged record to run
            // a repair that most of them have no copy for would be 56's lie in CLI
            // form — so the answer is looked up, not implied. One call for the
            // whole list: the per-path form re-reads the manifest per path (review
            // finding, 59). Paths that are not records simply have no plan.
            let damaged = report.issues.compactMap { issue -> String? in
                switch issue {
                case .unreadableRecord(let path, _), .missingFile(let path): path
                default: nil
                }
            }
            let plans = (try? opened.repairPlans(forRecordsAt: damaged)) ?? [:]
            for issue in report.issues {
                stdout.writeLine(describe(issue, plans: plans))
            }
            stdout.writeLine("\(report.issues.count) file-integrity issue(s) found.")
        }

        // **A note, not a finding** (slice 57b) — printed whether or not the
        // report is clean, for the same reason the abandonments below are: the
        // skip leaves nothing on disk to notice, so this is the only thing that
        // says the check was partial. It never touches the exit code.
        for line in Self.notCheckedLines(report) {
            stdout.writeLine(line)
        }

        // **Notes, not findings** (slice 50d) — printed regardless of `isClean`
        // and never affecting the exit, because an abandoned delivery is not a
        // problem with the archive: it is a decision this machine made, and the
        // manifest entry it left looks exactly like any other. Saying so is the
        // only thing that keeps it from being silent.
        if !report.abandonedPaths.isEmpty {
            stdout.writeLine("Abandoned deliveries (note — this machine stopped waiting):")
            for path in report.abandonedPaths {
                stdout.writeLine(
                    "  \(path)\tthis machine stopped waiting for it; if that version "
                        + "arrives later it will be taken up normally.")
            }
        }

        // Reported after the file report, regardless of it, and never affecting
        // the exit (informational — see the doc comment).
        if !dangling.isEmpty {
            stdout.writeLine("Dangling references (informational — §2.3, no cascade):")
            for reference in dangling {
                stdout.writeLine("  " + describe(reference))
            }
            stdout.writeLine(
                "\(dangling.count) dangling reference(s). Clean up the holders with "
                    + "`genea unrelate` / `genea unlink` / `genea fact remove` / "
                    + "`genea mention remove`.")
        }

        if !report.isClean {
            throw ExitCode.failure
        }
    }

    /// The one line a clean report prints — and the one sentence in this command
    /// that could claim more than it checked.
    ///
    /// The tracked count is here because "OK" alone cannot distinguish "checked
    /// everything, all good" from "there was nothing to check" — exactly what an
    /// archive last written before slice 49 looks like (its records carry no
    /// manifest entries until something writes to it, or `genea rebaseline`
    /// runs). Since 57b it must make a second distinction: **no problems found**
    /// stops meaning **verified** the moment anything is skipped, so an
    /// incomplete pass leads with PARTIAL and says how much it actually read.
    static func cleanLine(_ report: IntegrityReport) -> String {
        let tracked = report.trackedFileCount
        guard !report.isComplete else {
            return "OK: no integrity issues found (\(tracked) \(plural(tracked)) tracked)."
        }
        let skipped = report.notChecked.count
        let checked = tracked - skipped
        return
            "PARTIAL: no problems found in the \(checked) \(plural(checked)) checked, but "
            + "\(skipped) of \(tracked) tracked \(plural(tracked)) "
            + "\(skipped == 1 ? "was" : "were") not checked (see below)."
    }

    /// The unread files, why each went unread, and — when a download would in
    /// fact fix it — the flag that pays for one.
    ///
    /// **The size is the manifest's**, so stating it costs nothing and touches no
    /// disk — and a bare count is not something anyone can decide from, which is
    /// the whole reason the bytes are here.
    ///
    /// **Each line says its own reason** (`/code-review`, 57b). "Not downloaded"
    /// is true of a placeholder and false of a file that could not be read; and
    /// the closing line offers `--download-cloud-files` only when something here
    /// would actually be resolved by it, since downloading does nothing for a
    /// read error.
    static func notCheckedLines(_ report: IntegrityReport) -> [String] {
        guard !report.notChecked.isEmpty else { return [] }
        let count = report.notChecked.count
        var lines = ["Not checked (note — the contents of these files were not read):"]
        for file in report.notChecked {
            lines.append(
                "  \(file.path)\t\(friendlyBytes(file.byteLength))\t\(reason(file.reason))")
        }
        var closing =
            "\(count) \(plural(count)), \(friendlyBytes(report.notCheckedByteCount)) not checked."
        let downloadable = report.downloadableNotChecked.count
        if downloadable > 0 {
            closing +=
                " Re-run with --download-cloud-files to download and check "
                + "\(downloadable == count ? "them" : "the \(downloadable) not on this machine")."
        }
        lines.append(closing)
        return lines
    }

    /// Exhaustive on purpose: a new reason fails to compile here rather than
    /// printing under someone else's explanation.
    private static func reason(_ reason: IntegrityReport.NotCheckedFile.Reason) -> String {
        switch reason {
        case .notOnThisMachine:
            return "not downloaded to this machine; reading it would download it"
        case .couldNotRead:
            return "could not be read — check permissions and the disk it is on"
        case .checkWasStopped:
            return "the check was stopped before reading it"
        }
    }

    private static func plural(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }

    /// Friendly units with the exact byte count beside them: the first is what a
    /// human decides from, the second is what a script or a bug report needs.
    private static func friendlyBytes(_ bytes: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) (\(bytes) bytes)"
    }

    private func describe(
        _ issue: IntegrityReport.Issue, plans: [String: Archive.RecordRepairPlan] = [:]
    ) -> String {
        switch issue {
        case .checksumMismatch(let path, let expected, let actual):
            return "checksum-mismatch\t\(path)\texpected=\(expected) actual=\(actual)"
        case .missingFile(let path):
            guard let plan = plans[path] else { return "missing-file\t\(path)" }
            return "missing-file\t\(path)\t\(Self.vanishedRemedy(plan, archive: archive))"
        case .sizeMismatch(let path, let expected, let actual):
            return "size-mismatch\t\(path)\texpected=\(expected) actual=\(actual)"
        case .unreferencedFile(let path):
            return "unreferenced-file\t\(path)"
        case .interruptedWrite(let path):
            return
                "interrupted-write\t\(path)\ta write died before the manifest was updated; "
                + "run `genea rebaseline` to accept the file as it stands"
        case .awaitingDelivery(let path):
            return
                "awaiting-delivery\t\(path)\tthe manifest describes a version that has not "
                + "finished arriving from another machine; wait, then check again — do NOT "
                + "run `genea rebaseline`, which would discard the incoming version"
        case .conflictingCopy(let path):
            return
                "conflicting-copy\t\(path)\ta second copy of a record the archive already "
                + "has, most likely left by a sync provider that could not merge it; the "
                + "archive is using the original, not this file — read it, then delete it"
        case .misnamedRecord(let path, let uid):
            return
                "misnamed-record\t\(path)\tholds record \(uid) but is not named for it, and no "
                + "file with that name holds it either, so the archive does not load it — this "
                + "may be the only copy; rename it to \(uid).json, then run `genea reindex`"
        case .unreadableRecord(let path, .undecodable):
            let remedy =
                plans[path] != nil
                ? "GeneaLogic still has a copy — run `genea repair \(archive) --record \(path)`"
                : "GeneaLogic has no copy of it; repair or remove the file, then run "
                    + "`genea reindex`"
            return
                "unreadable-record\t\(path)\tcould not be read or decoded, so it is absent "
                + "from the index; \(remedy)"
        case .unreadableRecord(let path, .olderFormat):
            // Not damage (slice 64): the file reads, and `genea repair` refuses it,
            // so the line must not send anyone there.
            return
                "older-format-record\t\(path)\twas written in an older archive format than "
                + "the archive's manifest, so it is absent from the index; it is intact — do "
                + "not repair or replace it. An upgrade is what brings it forward"
        }
    }

    /// What a `missing-file` line says when the file was a record GeneaLogic kept
    /// a copy of (slice 58d): restore it, or delete it — which puts it back and
    /// deletes it the ordinary way, so an artifact lands in the trash.
    static func vanishedRemedy(_ plan: Archive.RecordRepairPlan, archive: String) -> String {
        let named = plan.recordLabel.map { "\"\($0)\" — " } ?? ""
        let restore = "genea repair \(archive) --record \(plan.path)"
        let opening = "\(named)a record GeneaLogic still has a copy of; restore it with `\(restore)`"
        guard plan.isDeletable else {
            // The file came back between the pass and the plan lookup.
            return "\(opening). Something is at that path now — run `genea verify \(archive)` again"
        }
        return "\(opening), or delete it with `\(restore) --delete`"
    }

    /// Each `DanglingReference` names the surviving **holder** first (the record a
    /// human edits or removes to resolve it) and the missing target second — the
    /// same framing the enum's cases document.
    private func describe(_ reference: DanglingReference) -> String {
        switch reference {
        case .relationshipEndpoint(let relationship, let missingPerson):
            return "relationship-endpoint\t\(relationship.raw)\tmissing person \(missingPerson.raw)"
        case .relationshipSupport(let relationship, let missingLink):
            return "relationship-support\t\(relationship.raw)\tmissing link \(missingLink.raw)"
        case .relationshipFactSupport(let relationship, let factIndex, let missingLink):
            return
                "relationship-fact-support\t\(relationship.raw) fact [\(factIndex)]"
                + "\tmissing link \(missingLink.raw)"
        case .personFactSupport(let person, let factIndex, let missingLink):
            return
                "person-fact-support\t\(person.raw) fact [\(factIndex)]"
                + "\tmissing link \(missingLink.raw)"
        case .linkArtifact(let link, let missingArtifact):
            return "link-artifact\t\(link.raw)\tmissing artifact \(missingArtifact.raw)"
        case .linkPerson(let link, let missingPerson):
            return "link-person\t\(link.raw)\tmissing person \(missingPerson.raw)"
        case .dismissalEndpoint(let dismissal, let missingPerson):
            return "dismissal-endpoint\t\(dismissal.raw)\tmissing person \(missingPerson.raw)"
        case .linkMention(let link, let artifact, let missingRef):
            return "link-mention\t\(link.raw)\tmissing mention \(missingRef) in \(artifact.raw)"
        case .mentionRelationshipEndpoint(let artifact, let edgeIndex, let missingRef):
            return
                "mention-relationship\t\(artifact.raw) relationship [\(edgeIndex)]"
                + "\tmissing mention \(missingRef)"
        }
    }
}
