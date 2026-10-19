// SPIKE 77 — throwaway. Never merged.
//
// `DocumentGroup` installs AppKit's document commands even for a read-only document,
// and `CommandGroup(replacing: .saveItem)` does not reach them. File ▸ Save on an
// unedited archive replaces the whole package. Remove the items from the AppKit menu.

import AppKit
import os

@MainActor
enum SpikeMenuSurgery {
    static let removed: Set<String> = [
        "saveDocument:", "saveDocumentAs:", "saveDocumentTo:", "duplicateDocument:",
        "revertDocumentToSaved:", "browseDocumentVersions:", "newDocument:",
    ]

    static func logFileMenu() {
        guard let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        for item in file.items {
            let sub =
                item.submenu?.items.map {
                    "\($0.title)=\($0.action.map(NSStringFromSelector) ?? "-")"
                } ?? []
            spikeQ1Log.notice(
                "MENU \(item.title, privacy: .public) action=\(item.action.map(NSStringFromSelector) ?? "-", privacy: .public) sub=\(sub.joined(separator: ", "), privacy: .public)"
            )
        }
    }

    static func run() {
        guard let menu = NSApp.mainMenu else { return }
        prune(menu)
    }

    private static func prune(_ menu: NSMenu) {
        for item in menu.items.reversed() {
            if let action = item.action, removed.contains(NSStringFromSelector(action)) {
                menu.removeItem(item)
            } else if let sub = item.submenu {
                prune(sub)
                if sub.items.allSatisfy({ $0.isSeparatorItem }) && !sub.items.isEmpty
                    || (sub.items.isEmpty && item.action == nil && menu !== NSApp.mainMenu)
                {
                    menu.removeItem(item)
                }
            }
        }
    }
}
