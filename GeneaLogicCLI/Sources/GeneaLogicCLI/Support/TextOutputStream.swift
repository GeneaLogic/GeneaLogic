import Foundation

/// A simple, injectable output sink (ARCHITECTURE.md-style "output-stream
/// discipline" — see the CLI README): every command writes its normal results
/// through a `stdout`-shaped sink and its diagnostics through a `stderr`-shaped
/// one, rather than calling `print`/`FileHandle.standardError` directly.
///
/// This is what lets `GeneaLogicCLITests` capture a command's output and assert
/// on it (ArgumentParser's `run()` has no return value, so the contract for
/// `list`/`find`/`verify` etc. — their printed text and exit behavior — has to be
/// observable some other way).
public protocol CLIOutput {
    func writeLine(_ line: String)
}

/// Writes to the process's real `stdout`/`stderr` (the production sink).
///
/// `@unchecked Sendable`: `FileHandle` itself isn't `Sendable` on every
/// platform/SDK version, but `.standardOutput`/`.standardError` are
/// process-wide singletons and `writeLine` only calls the thread-safe
/// `write(_:)` — there is no mutable state here for concurrent access to race on.
public struct StandardOutput: CLIOutput, @unchecked Sendable {
    private let handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public static let out = StandardOutput(handle: .standardOutput)
    public static let err = StandardOutput(handle: .standardError)

    public func writeLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }
}

/// An in-memory sink for tests: collects every line written, in order.
public final class CollectingOutput: CLIOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    public init() {}

    public func writeLine(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    /// All written lines, in order.
    public var allLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// All written lines joined by `"\n"`, with a trailing newline — the same
    /// shape as what would have landed on a real stream.
    public var text: String {
        allLines.map { $0 + "\n" }.joined()
    }
}
