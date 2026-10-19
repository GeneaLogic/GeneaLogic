// SPIKE 77, question 0 — throwaway. Never merged.
//
// A writable `Document` over a scratch package (`*.geneaspike`) that logs where a
// save writes and what it finds there, so the premise behind 77's read-only design
// can be checked: is `destination` the document's own URL, and how does the result
// replace the original?

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

nonisolated let spikeLog = Logger(subsystem: "app.genealogic.spike77", category: "q0")

extension UTType {
    static let spikeScratch = UTType(
        exportedAs: "app.genealogic.spike-scratch", conformingTo: .package)
}

/// Lists a directory's children with inode numbers, for comparing before and after a save.
nonisolated func spikeDescribe(_ url: URL) -> String {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
        return "\(url.path): <missing>"
    }
    var lines = ["\(url.path) inode=\(attrs[.systemFileNumber] ?? "?")"]
    for name in ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() {
        let child = url.appending(path: name)
        let a = try? fm.attributesOfItem(atPath: child.path)
        lines.append("  \(name) inode=\(a?[.systemFileNumber] ?? "?") size=\(a?[.size] ?? "?")")
    }
    return lines.joined(separator: "\n")
}

@Observable
final class ScratchDocument: Document {
    static let readableContentTypes: [UTType] = [.spikeScratch]

    var counter = 0
    @ObservationIgnored let configuration: URLDocumentConfiguration

    init(configuration: URLDocumentConfiguration) {
        self.configuration = configuration
    }

    struct Reader: DocumentReader {
        @concurrent
        func read(from source: URL, progress: consuming Subprogress) async throws -> sending Int {
            spikeLog.notice(
                "READ source=\(source.path, privacy: .public)\n\(spikeDescribe(source), privacy: .public)"
            )
            let data = try? Data(contentsOf: source.appending(path: "counter.txt"))
            return data.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        }
    }

    func reader(configuration: sending ReadConfiguration) -> sending Reader { Reader() }

    @MainActor
    func apply(snapshot: sending Int, previous: sending Int?) async throws {
        counter = snapshot
    }

    /// Carries the document's URL into the writer: `URLDocumentConfiguration.fileURL`
    /// is main-actor isolated, and `writer(configuration:)` is called off the main
    /// actor during a save (reading it there crashed the first run).
    struct WriteSnapshot: Sendable {
        var counter: Int
        var fileURL: URL?
    }

    struct Writer: DocumentWriter {
        @concurrent
        func write(
            snapshot: sending WriteSnapshot, to destination: URL, previous: sending WriteSnapshot?,
            progress: consuming Subprogress
        ) async throws {
            let fileURL = snapshot.fileURL
            spikeLog.notice(
                """
                WRITE destination=\(destination.path, privacy: .public) \
                fileURL=\(fileURL?.path ?? "nil", privacy: .public) \
                same=\(destination.standardizedFileURL == fileURL?.standardizedFileURL, privacy: .public)
                destination before:
                \(spikeDescribe(destination), privacy: .public)
                original before:
                \(fileURL.map(spikeDescribe) ?? "-", privacy: .public)
                """)
            let fm = FileManager.default
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data(String(snapshot.counter).utf8).write(to: destination.appending(path: "counter.txt"))
            spikeLog.notice(
                "WRITE done; destination after:\n\(spikeDescribe(destination), privacy: .public)")
        }
    }

    func writer(configuration: sending WriteConfiguration) -> sending Writer {
        Writer()
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending WriteSnapshot {
        WriteSnapshot(counter: counter, fileURL: configuration.fileURL)
    }
}

struct ScratchDocumentView: View {
    @Bindable var document: ScratchDocument
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 12) {
            Text("Spike 77 · q0 — counter \(document.counter)")
            Button("Increment") { increment() }
        }
        .padding(40)
        .task {
            // Make one undoable change on open, so autosave has something to save.
            try? await Task.sleep(for: .seconds(1))
            increment()
            // A change made outside an event leaves its undo group open until the next
            // event, so the document never notices it. Post one.
            NSApp.postEvent(
                NSEvent.otherEvent(
                    with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
    }

    private func increment() {
        let old = document.counter
        document.counter += 1
        undoManager?.registerUndo(withTarget: document) { $0.counter = old }
        spikeLog.notice("EDIT counter \(old) -> \(document.counter) undoManager=\(undoManager == nil ? "nil" : "set", privacy: .public) canUndo=\(undoManager?.canUndo ?? false, privacy: .public)")
    }
}
