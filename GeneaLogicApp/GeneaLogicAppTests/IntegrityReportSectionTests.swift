import Foundation
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// The panel groups findings into sections by severity, and renders **only** the
/// severities its section list names. A severity with no section is not a
/// cosmetic gap: a report whose findings all share it skips the "Archive Is
/// Intact" branch (it is not clean) and then renders a `List` with zero sections
/// — a blank sheet, on the surface the banner deliberately stays silent in favour
/// of.
///
/// `IntegrityReportSheet`'s own doc comment has claimed since slice 60 that a
/// test holds this. **It did not exist** — found while adding `.duplicate` in
/// 50c, which is to say the one time the promised net was needed it was not
/// there. Now it is.
@MainActor
@Suite struct IntegrityReportSectionTests {

    @Test func sectionsCoverEverySeverity() {
        let covered = Set(IntegrityReportSheet.sections.map(\.severity))
        for severity in IntegrityReport.Issue.Severity.allCases {
            #expect(covered.contains(severity), "no section renders \(severity)")
        }
    }

    /// Two sections for one severity would render its findings twice.
    @Test func noSeverityHasTwoSections() {
        let severities = IntegrityReportSheet.sections.map(\.severity)
        #expect(Set(severities).count == severities.count)
    }

    /// Every issue kind maps to a severity that has a section, which is the
    /// property the two tests above only imply. Kinds carrying a payload are
    /// listed with a sample one; the switch in `severity` is exhaustive, so a new
    /// kind fails to compile here rather than rendering nowhere.
    @Test func everyIssueKindReachesASection() {
        let issues: [IntegrityReport.Issue] = [
            .checksumMismatch(path: "p", expected: "a", actual: "b"),
            .missingFile(path: "p"),
            .sizeMismatch(path: "p", expected: 1, actual: 2),
            .unreferencedFile(path: "p"),
            .interruptedWrite(path: "p"),
            .awaitingDelivery(path: "p"),
            .unreadableRecord(path: "p", reason: .undecodable),
            .conflictingCopy(path: "p"),
            .misnamedRecord(path: "p", uid: "PER-1"),
        ]
        let covered = Set(IntegrityReportSheet.sections.map(\.severity))
        for issue in issues {
            #expect(covered.contains(issue.severity), "\(issue.summary) renders nowhere")
        }
    }
}
