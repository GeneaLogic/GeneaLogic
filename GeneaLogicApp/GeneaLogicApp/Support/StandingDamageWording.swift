//
//  StandingDamageWording.swift
//  GeneaLogicApp
//

import Foundation
import GeneaLogicArchive

/// What the standing-damage banner says (slice 56) — lifted out of the view in
/// slice 71 so the wording is held by tests rather than by hand-tests alone.
///
/// Its first test is the line the exit review found: "a change also didn't finish, so a
/// record may be out of date" counted older-format records as damage, because it
/// checked the whole skipped list after 64 split the rest of the banner by reason.
struct StandingDamageWording {
    let findings: Archive.StandingFindings
    /// Unreadable records with no browse list of their own — named here, since the
    /// banner is the only place they appear.
    let otherRecords: [UnreadableRecordRow]
    /// The files the banner names: the sweep's findings, plus any record whose
    /// file is gone that the sweep hasn't reported yet (slice 58d, fork g).
    ///
    /// **Merged here, not by the caller** (`/code-review`, 71): a vanished record
    /// is a standing finding, so the banner can be up before any sweep has
    /// finished, and a value built without the merge fell through to "A change to
    /// this archive didn't finish", which is false. The sweep says the same thing
    /// the moment it runs; this only closes the gap before then.
    let fileDamage: FileDamageSummary?

    init(
        findings: Archive.StandingFindings, otherRecords: [UnreadableRecordRow],
        sweep: FileDamageSummary?
    ) {
        self.findings = findings
        self.otherRecords = otherRecords
        self.fileDamage = FileDamageSummary.merging(sweep, missing: findings.vanished)
    }

    /// **Missing files take the headline when there are any** (slice 57), and the
    /// record findings fold into the detail line below. A tracked file that is
    /// gone or truncated is the more concrete loss, and its paths belong directly
    /// under it since nothing else ever names them.
    ///
    /// With no file damage — the overwhelmingly common case — this is 56's
    /// behaviour unchanged, which is what keeps its hand-tested wording intact.
    /// The skipped records, split by what may honestly be said about them
    /// (slice 64): "couldn't be read" is damage, and an older-format record is
    /// not — it is intact and merely left out until an upgrade.
    private var unreadableCount: Int { findings.undecodableRecords.count }
    private var olderFormatCount: Int { findings.unreadable.count - unreadableCount }

    var headline: String {
        if let fileDamage { return fileDamage.headline }
        switch (unreadableCount, olderFormatCount) {
        case (0, 0):
            return "A change to this archive didn't finish"
        case (1, _):
            return "1 record in this archive couldn't be read"
        case (let count, _) where count > 1:
            return "\(count) records in this archive couldn't be read"
        case (_, 1):
            return "1 record in this archive is in an older format"
        case (_, let count):
            return "\(count) records in this archive are in an older format"
        }
    }

    var detail: String? {
        var parts: [String] = []
        if let fileDamage {
            parts.append(fileDamage.pathSummary)
            // Displaced from the headline by the file findings, so it is said
            // here instead of dropped.
            if unreadableCount == 1 {
                parts.append("1 record also couldn't be read.")
            } else if unreadableCount > 1 {
                parts.append("\(unreadableCount) records also couldn't be read.")
            }
        }
        // Said here whenever the headline is about something else, so a
        // straggler is never counted as damage and never goes unmentioned.
        if fileDamage != nil || unreadableCount > 0 {
            if olderFormatCount == 1 {
                parts.append("1 record is in an older format and isn't shown.")
            } else if olderFormatCount > 1 {
                parts.append("\(olderFormatCount) records are in an older format and aren't shown.")
            }
        }
        if !otherRecords.isEmpty {
            // These have no row anywhere, so the banner is the only place they
            // are ever named.
            parts.append(otherRecords.map(\.path).joined(separator: ", "))
        }
        if findings.interruptedWriteSuspected && unreadableCount > 0 {
            parts.append("A change also didn't finish, so a record may be out of date.")
        } else if findings.interruptedWriteSuspected {
            parts.append("A record may not match what the archive recorded for it.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
