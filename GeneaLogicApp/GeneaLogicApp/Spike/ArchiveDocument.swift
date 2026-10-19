// SPIKE 77 — throwaway. Never merged.
//
// A read-only `DocumentGroup` document for a `.genea` archive. The reader hands over
// nothing but the URL it was given; the engine opens the archive itself, in
// `ArchiveModel.load()`, as it does today.

import SwiftUI
import UniformTypeIdentifiers
import os

nonisolated let spikeQ1Log = Logger(subsystem: "app.genealogic.spike77", category: "q1")

@Observable
final class ArchiveDocument: ReadableDocument {
    static let readableContentTypes: [UTType] = [.geneaArchive]

    var url: URL?
    @ObservationIgnored let configuration: URLDocumentConfiguration

    init(configuration: URLDocumentConfiguration) {
        self.configuration = configuration
        spikeQ1Log.notice(
            "MAKE configuration.fileURL=\(configuration.fileURL?.path ?? "nil", privacy: .public)")
    }

    struct Reader: DocumentReader {
        @concurrent
        func read(from source: URL, progress: consuming Subprogress) async throws -> sending URL {
            spikeQ1Log.notice(
                "READ source=\(source.path, privacy: .public) main=\(Thread.isMainThread, privacy: .public)"
            )
            return source
        }
    }

    func reader(configuration: sending ReadConfiguration) -> sending Reader { Reader() }

    @MainActor
    func apply(snapshot: sending URL, previous: sending URL?) async throws {
        spikeQ1Log.notice(
            "APPLY snapshot=\(snapshot.path, privacy: .public) previous=\(previous?.path ?? "nil", privacy: .public) fileURL=\(self.configuration.fileURL?.path ?? "nil", privacy: .public)"
        )
        // The window's existing access bookkeeping expects a URL it has acquired.
        ArchiveAccessStore.shared.acquire(snapshot)
        url = snapshot
    }
}

struct ArchiveDocumentView: View {
    let document: ArchiveDocument

    var body: some View {
        if let url = document.url {
            if UserDefaults.standard.bool(forKey: "Spike77NoLoad") {
                // Opens the document without the engine, to see what SwiftUI reads on its own.
                Text("Spike 77 · q1 — \(url.lastPathComponent), engine not opened")
                    .padding(40)
            } else {
                ArchiveContainerView(url: url)
                    .id(url)
                    .background(SpikeSaveBlockerInstaller())
            }
        } else {
            ProgressView()
        }
    }
}
