import SwiftUI

// Run, scroll the inspector a little, and look at its text under the toolbar: it is sharp.
// Click the Inspector button twice and scroll again: it is now blurred by the toolbar's
// edge. Delete the `inspectorColumnWidth` line and it is sharp both times.
//
// INSPECTOR_WORKAROUND=1 applies GeneaLogic's workaround (slice 80): content is cut at
// the toolbar's lower edge, so it looks the same both times.
let workaround = ProcessInfo.processInfo.environment["INSPECTOR_WORKAROUND"] == "1"

struct InspectorRows: View {
    var body: some View {
        let rows = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(1..<60) { Text("Inspector row \($0)") }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if workaround {
            rows
                .scrollEdgeEffectHidden(true, for: .top)
                .mask { Rectangle().ignoresSafeArea(.container, edges: .bottom) }
        } else {
            rows
        }
    }
}

struct ContentView: View {
    @State private var selection: Int? = 1
    @State private var inspectorShown = true

    var body: some View {
        NavigationSplitView {
            List(1..<10, id: \.self, selection: $selection) { Text("Item \($0)") }
        } detail: {
            Text("Detail for item \(selection ?? 0)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: $inspectorShown) {
                    InspectorRows()
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
                }
                .toolbar {
                    Button("Inspector", systemImage: "info.circle") { inspectorShown.toggle() }
                }
        }
    }
}

@main
struct InspectorEdgeApp: App {
    var body: some Scene {
        WindowGroup { ContentView().frame(minWidth: 900, minHeight: 500) }
    }
}
