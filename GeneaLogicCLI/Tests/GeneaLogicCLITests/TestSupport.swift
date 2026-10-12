import Foundation

/// Shared test scaffolding for `GeneaLogicCLITests` — mirrors
/// `GeneaLogicArchiveTests/TestSupport.swift` (each test gets its own throwaway
/// directory; the OS cleans up `NSTemporaryDirectory()`).
enum TestSupport {
    static func makeTempDirectory(function: String = #function) -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let safeName = function.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let url = base.appendingPathComponent(
            "GeneaLogicCLITests-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A throwaway source file (for `genea attach`) with the given contents,
    /// written into its own fresh temp directory so concurrent tests never
    /// collide on a shared filename.
    static func makeSourceFile(named name: String = "source.txt", contents: String = "hello")
        throws -> URL
    {
        let directory = makeTempDirectory(function: "source-\(UUID().uuidString)")
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
