import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea rebaseline <archive>` → `rebaseline()`.
///
/// The resolution for an edit the engine didn't make: spec §5.1 blesses
/// hand-editing a sidecar, and since slice 49 that edit reports as a
/// `checksum-mismatch` — indistinguishable, by design, from bit rot. This is how
/// a human says which one it was.
struct RebaselineCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "rebaseline",
        abstract: "Accept the archive's current contents: rebuild the index and re-record "
            + "every checksum from what is on disk.",
        discussion: """
            Use this after editing a record by hand, or after `genea verify` reports an \
            interrupted write. It records what is there now, so anything reported \
            afterwards is new.

            It will not hide bit rot in an attached file: a media file's checksum is \
            authored in its artifact's record.json, and this command does not rewrite records.

            Records it cannot read are left exactly as they are, checksum included: \
            there is no version of such a record on disk to accept, and that recorded \
            checksum is what lets `genea repair` prove a restore is byte-identical.
            """
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        try opened.rebaseline()
        stdout.writeLine("Rebaselined: the manifest now records the archive as it stands.")
    }
}
