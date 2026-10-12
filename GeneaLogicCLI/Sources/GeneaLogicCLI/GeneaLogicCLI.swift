import ArgumentParser

/// `genea` — the headless command-line front-end for a GeneaLogic archive
/// (Phase 1b, docs/slices/phase-0-1.md). Every subcommand operates on an on-disk archive
/// directory (a `.genea`-style package per ARCHITECTURE.md §3) via
/// `GeneaLogicArchive.Archive`.
///
/// Subcommands are thin: each parses its arguments, opens/creates the archive,
/// calls exactly the engine API named in its doc comment, and renders the
/// result. Normal results go to stdout; errors go to stderr with a non-zero
/// exit (see `CLIError`).
///
/// The command list has two eras. The Phase-1 verbs (`create`/`add`/`attach`/
/// `set-meta`/`find`/`list`/`show`/`reindex`/`verify`/`set-role`/`replace-file`/
/// `lookup`) are **artifact**-scoped by convention — they predate there being
/// anything else to address, and the read/file verbs 44d adds stay flat with
/// them. Phase 3's conclusions surface groups under nouns (`person …`, `fact …`,
/// `relationship …`, `trash …`, `match …`), with only the genuinely two-sided verbs
/// left flat (`relate`/`unrelate`, `link`/`unlink`). The artifact-scoped evidence
/// sub-records get their own nouns too (`mention …`, `event …`, `place …`, each
/// taking the artifact positionally) — a flat `add` could no longer say *what* it
/// adds.
@main
struct GeneaLogicCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genea",
        abstract: "A headless command-line front-end for a GeneaLogic archive.",
        subcommands: [
            CreateCommand.self,
            SampleCommand.self,
            AddCommand.self,
            AttachCommand.self,
            SetMetaCommand.self,
            SetRoleCommand.self,
            ReplaceFileCommand.self,
            VerifyCommand.self,
            ReindexCommand.self,
            RebaselineCommand.self,
            AbandonDeliveryCommand.self,
            RepairCommand.self,
            UpgradeCommand.self,
            ListCommand.self,
            FindCommand.self,
            LookupCommand.self,
            ShowCommand.self,
            RemoveCommand.self,
            DetachCommand.self,
            EventCommand.self,
            PlaceCommand.self,
            PersonCommand.self,
            MentionCommand.self,
            RelateCommand.self,
            UnrelateCommand.self,
            RelationshipCommand.self,
            LinkCommand.self,
            UnlinkCommand.self,
            MatchCommand.self,
            FactCommand.self,
            TrashCommand.self,
        ]
    )
}
