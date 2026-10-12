import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea find <archive> [<query>] [--tag <t> ...] [--source-tier <s>]
/// [--from-year <y>] [--to-year <y>] [--mentioning <name>]` →
/// `artifacts(matching: ArtifactQuery(...))`.
///
/// The structured half of §5.1, exposing the whole `ArtifactQuery`, not just its
/// free text. `<query>` is the case-insensitive substring match over
/// title/transcript/notes/evidence fields (`ArtifactQuery.text`); the facets add
/// an *exact* whole-tag match (`--tag`, repeatable), a source-tier filter, an
/// event-date-overlap range (`--from-year`/`--to-year`), and a name-as-recorded
/// substring (`--mentioning`). **The engine ANDs them all** (the app's slice-13
/// tag filter rides exactly this). Output is the same pipe-friendly `<uid>\t<title>`
/// as `list`.
///
/// `--mentioning` is the free-text mention match; the *conclusions-aware* "which
/// artifacts cite this concluded person" lookup is `lookup --mentions <PER-uid>`.
struct FindCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find artifacts by free text and/or structured facets."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "Free-text query, matched against title/transcript/notes/evidence.")
    var query: String?

    @Option(name: .long, parsing: .singleValue, help: "An exact tag to require (repeatable).")
    var tag: [String] = []

    @Option(name: .customLong("source-tier"), help: "Only artifacts with this source tier.")
    var sourceTier: String?

    @Option(
        name: .customLong("from-year"), help: "Only artifacts with an event on or after this year.")
    var fromYear: Int?

    @Option(
        name: .customLong("to-year"), help: "Only artifacts with an event on or before this year.")
    var toYear: Int?

    @Option(name: .long, help: "Only artifacts naming this text among their mentions.")
    var mentioning: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        // At least one criterion, or `find` silently becomes `list`.
        guard
            query != nil || !tag.isEmpty || sourceTier != nil || fromYear != nil
                || toYear != nil || mentioning != nil
        else {
            throw CLIUserError(
                "Give a query or at least one facet (--tag, --source-tier, --from-year, "
                    + "--to-year, --mentioning). Use `genea list` to list everything.")
        }

        // A one-sided year bound is valid: the missing side opens to ±∞, which
        // `EDTFDate.overlaps(years:)` handles directly. A *reversed* pair is not —
        // `(lower)...(upper)` traps when `lower > upper`, so catch it as a usage
        // error rather than letting the range constructor fatal-error the process.
        let dateRange: ClosedRange<Int>?
        if fromYear != nil || toYear != nil {
            let lower = fromYear ?? Int.min
            let upper = toYear ?? Int.max
            guard lower <= upper else {
                throw CLIUserError("--from-year must be on or before --to-year.")
            }
            dateRange = lower...upper
        } else {
            dateRange = nil
        }

        let queryValue = ArtifactQuery(
            text: query,
            tags: tag,
            sourceTier: sourceTier.map { .parsing($0) },
            dateRange: dateRange,
            mentioning: mentioning
        )
        for summary in opened.artifacts(matching: queryValue) {
            stdout.writeLine("\(summary.uid.raw)\t\(summary.title)")
        }
    }
}
