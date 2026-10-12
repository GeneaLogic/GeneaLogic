import Foundation
import Testing
import UniformTypeIdentifiers

@testable import GeneaLogicApp

/// Slice 75 — the document type the Swift code names is the one `Info.plist` exports.
///
/// Reads the app's own `Info.plist` (the test host is the app, so `Bundle.main`),
/// never Launch Services: what the system resolves for `.genea` depends on every
/// bundle registered on the machine, including stale builds, so it can't pin this
/// bundle's declaration.
@Suite struct ArchiveTypeTests {

    private func info<T>(_ key: String, as: T.Type = T.self) throws -> T {
        try #require(Bundle.main.infoDictionary?[key] as? T, "Info.plist has no \(key)")
    }

    @Test func infoPlistExportsTheSwiftType() throws {
        let exported = try info("UTExportedTypeDeclarations", as: [[String: Any]].self)
        let declaration = try #require(exported.only)

        #expect(declaration["UTTypeIdentifier"] as? String == UTType.geneaArchive.identifier)
        #expect(
            declaration["UTTypeConformsTo"] as? [String] == [
                UTType.package.identifier, UTType.compositeContent.identifier,
            ])
        let tags = declaration["UTTypeTagSpecification"] as? [String: [String]]
        #expect(tags?["public.filename-extension"] == ["genea"])
    }

    @Test func theAppOpensTheTypeItExports() throws {
        let documentTypes = try info("CFBundleDocumentTypes", as: [[String: Any]].self)
        let documentType = try #require(documentTypes.only)

        #expect(documentType["LSItemContentTypes"] as? [String] == [UTType.geneaArchive.identifier])
        #expect(documentType["LSHandlerRank"] as? String == "Owner")
    }
}

extension Array {
    /// The single element, or `nil` when there are none or several.
    fileprivate var only: Element? { count == 1 ? first : nil }
}
