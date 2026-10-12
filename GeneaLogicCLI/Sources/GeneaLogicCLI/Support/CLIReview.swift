import Foundation
import GeneaLogicArchive

/// Reporting for the link-review writes (`link`, and 45d's `match confirm`/`reject`).
///
/// A pair holds one verdict, so writing one can displace another — and displacing a link
/// can strand a fact's `supportedByLinks` citation. Every other removal in this CLI says
/// what it cost at the moment it happened (`person remove`, `mention remove`, `remove`
/// all print a "left dangling" line); these writes are removals too whenever they
/// supersede, and they say so the same way.
enum CLIReview {

    /// Prints what a link write displaced, if anything. Silent on the ordinary path,
    /// where nothing existed for the pair.
    static func reportDisplacement(_ decision: ReviewDecision, to stdout: CLIOutput) {
        guard !decision.superseded.isEmpty else { return }

        let replaced = decision.superseded
            .map { "\($0.uid.raw) (\($0.reviewStatus.rawValue))" }
            .joined(separator: ", ")
        stdout.writeLine("Replaced the previous verdict on this pair: \(replaced)")

        guard !decision.strandedCitations.isEmpty else { return }
        stdout.writeLine(
            "\(decision.strandedCitations.count) citation(s) now dangle — "
                + "see `genea verify`.")
    }
}
