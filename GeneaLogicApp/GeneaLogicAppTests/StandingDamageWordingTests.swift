import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 71 — the damage banner words a skipped record by why it was
/// skipped, including in the line about an interrupted write.
@MainActor
@Suite struct StandingDamageWordingTests {

    private func wording(
        _ reasons: [UnreadableRecordReason], interrupted: Bool
    ) -> StandingDamageWording {
        let unreadable = reasons.enumerated().map { index, reason in
            UnreadableRecord(path: "conclusions/persons/PER-\(index).json", reason: reason)
        }
        return StandingDamageWording(
            findings: Archive.StandingFindings(
                unreadable: unreadable, interruptedWriteSuspected: interrupted),
            otherRecords: [], sweep: nil)
    }

    /// The finding: an older-format record is intact, so it is not the record
    /// a died write may have left out of date.
    @Test func anOlderFormatRecordIsNotWhatTheDiedWriteLeftBehind() {
        let said = wording([.olderFormat], interrupted: true)
        #expect(said.headline == "1 record in this archive is in an older format")
        #expect(said.detail == "A record may not match what the archive recorded for it.")
    }

    @Test func anUnreadableRecordStillIs() {
        let said = wording([.undecodable, .olderFormat], interrupted: true)
        #expect(said.headline == "1 record in this archive couldn't be read")
        #expect(
            said.detail
                == "1 record is in an older format and isn't shown. · "
                + "A change also didn't finish, so a record may be out of date.")
    }

    @Test func aDiedWriteAloneTakesTheHeadline() {
        let said = wording([], interrupted: true)
        #expect(said.headline == "A change to this archive didn't finish")
        #expect(said.detail == "A record may not match what the archive recorded for it.")
    }

    /// A record whose file is gone, before any sweep has run, is a missing file —
    /// not "a change didn't finish" (`/code-review`, 71).
    @Test func aVanishedRecordBeforeTheSweepIsAMissingFile() {
        let path = "conclusions/persons/PER-gone.json"
        let said = StandingDamageWording(
            findings: Archive.StandingFindings(vanished: [path]), otherRecords: [], sweep: nil)
        #expect(said.headline == "1 file is missing from this archive")
        #expect(said.fileDamage?.paths == [path])
    }
}
