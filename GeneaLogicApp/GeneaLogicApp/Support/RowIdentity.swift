import SwiftUI

// Row identity for the editable lists (slice 79b).
//
// A row is identified by **what it shows**, never by where it sits: its key (the value
// itself, or a mention's `localRef`) plus its occurrence among rows with the same key. So
// deleting a mid-list row removes *that* row's view, and the rows below keep their own
// state, instead of each slot inheriting the state of the row above it. The id is derived
// rather than stored, so it survives every reload, and nothing on disk changes.
//
// A write is addressed the same way. The index a row was drawn at is only a **hint**,
// checked against the key, because the write runs on a freshly read record that another
// writer or an undo may have shifted since. So the identity types and the array helpers
// are `nonisolated`: a write's closure runs off the main actor (slice 52).

/// A row's identity: its key, and how many earlier rows share that key.
nonisolated struct RowKey<Key: Hashable>: Hashable {
    let key: Key
    let occurrence: Int
}

/// One element of a list, with its identity and the index it was drawn at.
nonisolated struct KeyedRow<Key: Hashable, Element>: Identifiable {
    let id: RowKey<Key>
    /// The element's position in the list it was keyed from: the hint a write starts at.
    let index: Int
    let element: Element
}

nonisolated extension Array {
    /// The elements keyed by `key`, each with its occurrence among equal keys.
    func keyedRows<Key: Hashable>(by key: (Element) -> Key) -> [KeyedRow<Key, Element>] {
        var seen: [Key: Int] = [:]
        return enumerated().map { index, element in
            let k = key(element)
            let occurrence = seen[k, default: 0]
            seen[k] = occurrence + 1
            return KeyedRow(
                id: RowKey(key: k, occurrence: occurrence), index: index, element: element)
        }
    }

    /// Where the element a row was drawn from is now: `hint` if the element there still
    /// matches, else the first that does, else `nil` (it is gone, and a write does
    /// nothing).
    func position(near hint: Int, where matches: (Element) -> Bool) -> Int? {
        if indices.contains(hint), matches(self[hint]) { return hint }
        return firstIndex(where: matches)
    }
}

nonisolated extension Array where Element: Hashable {
    /// The elements keyed by their own value.
    func keyedRows() -> [KeyedRow<Element, Element>] { keyedRows { $0 } }

    /// Where `expected` is now. See `position(near:where:)`.
    func position(of expected: Element, near hint: Int) -> Int? {
        position(near: hint) { $0 == expected }
    }
}

// MARK: - Focus after an edit

/// A row's edit control and the focus state it binds to. Type-erased, so one
/// `@FocusState` can serve rows keyed by different types.
struct RowFocus {
    let state: FocusState<AnyHashable?>.Binding
    let id: AnyHashable
}

/// Brings keyboard focus back to a row after its edit sheet replaced it.
///
/// An edit changes the row's value, and so its identity: the view that held focus is gone
/// by the time the sheet closes, and focus would otherwise fall back to the start of the
/// pane. So the sheet reports what it wrote, and focus moves to the row that now shows it.
///
/// Two things have to have happened first, in either order: the reload that brings in the
/// new value, and the end of the sheet's dismissal (focus set while it is still closing is
/// lost when it finishes). So the request remembers which one came first. Only an edit
/// opened from a focused row, and one that changed something, asks for this, so a mouse
/// user never gets a focus ring they didn't have.
struct RowFocusReturn<Key: Hashable> {
    /// The key of the value the edit wrote.
    let key: Key
    /// The index the edited row was drawn at.
    let hint: Int
    private var sheetIsGone = false
    /// The written row, once a reload has brought it in.
    private var arrived: AnyHashable?

    init(key: Key, hint: Int) {
        self.key = key
        self.hint = hint
    }

    /// The row now showing the written value: the one at `hint` if its key matches, else
    /// the first that does.
    func target<Element>(in rows: [KeyedRow<Key, Element>]) -> AnyHashable? {
        let matching = rows.filter { $0.id.key == key }
        return (matching.first { $0.index == hint } ?? matching.first).map { AnyHashable($0.id) }
    }

    /// After a reload: the row to focus now, if the sheet has already closed. A reload
    /// after it closed answers the request either way, so one whose write found nothing
    /// to replace is dropped rather than left to fire on some later, unrelated reload.
    static func reloaded<Element>(
        _ request: inout RowFocusReturn?, rows: [KeyedRow<Key, Element>]
    ) -> AnyHashable? {
        guard var pending = request else { return nil }
        let target = pending.target(in: rows)
        if pending.sheetIsGone {
            request = nil
            return target
        }
        pending.arrived = target
        request = pending
        return nil
    }

    /// When the sheet has finished closing: the row to focus now, if its reload has
    /// already landed.
    static func sheetClosed(_ request: inout RowFocusReturn?) -> AnyHashable? {
        guard var pending = request else { return nil }
        if let arrived = pending.arrived {
            request = nil
            return arrived
        }
        pending.sheetIsGone = true
        request = pending
        return nil
    }
}

extension View {
    /// Binds this control to `focus` when one is given.
    @ViewBuilder
    func rowFocus(_ focus: RowFocus?) -> some View {
        if let focus {
            focused(focus.state, equals: focus.id)
        } else {
            self
        }
    }
}
