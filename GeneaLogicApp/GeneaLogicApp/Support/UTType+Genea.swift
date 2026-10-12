import UniformTypeIdentifiers

extension UTType {
    /// The `.genea` archive package type, exported by the app's `Info.plist`
    /// (`UTExportedTypeDeclarations`, slice 75). The identifier here and there must
    /// agree; `ArchiveTypeTests` checks that they do.
    static let geneaArchive = UTType(
        exportedAs: "app.genealogic.archive", conformingTo: .package)
}
