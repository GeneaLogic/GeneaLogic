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

/// What an editor reports about an edit, so the row it replaced can take focus back
/// (79b). `saved` is called as the editor saves, with the value it is writing; `committed`
/// once the write has committed, with that value and the list it lives in as the write
/// left it (`nil` if the record is gone).
struct EditReport<Value> {
    let saved: (Value) -> Void
    let committed: (Value, [Value]?) -> Void
}

/// Brings keyboard focus back to a row after its edit sheet replaced it.
///
/// An edit changes the row's value, and so its identity: the view that held focus is gone
/// by the time the sheet closes, and focus would otherwise fall back to the start of the
/// pane. So the editor reports where its value ended up, and focus moves to that row.
///
/// The target is taken from the **committed** record, never guessed from a reload: a
/// reload can land before the write does (it waits on the archive lock), and a write that
/// found nothing to replace changes nothing to reload. Focus then waits for two things,
/// in either order: the row's view (the reload after the commit) and the end of the
/// sheet's dismissal (focus set while it is still closing is lost when it finishes).
///
/// Only an edit opened from a focused row, that changed something, asks for this, so a
/// mouse user never gets a focus ring they didn't have. The rules live in one place:
/// `request(for:…)` starts it, `sheetClosed` marks the close, and `returnsRowFocus`
/// settles it against the rows on screen.
struct RowFocusReturn: Equatable {
    private enum Stage: Equatable {
        /// The editor is open, and hasn't saved.
        case editing
        /// Saved; the write hasn't committed.
        case saved
        /// Committed: the written row's id in the committed record.
        case committed(AnyHashable)
    }

    private var stage = Stage.editing
    private var sheetIsGone = false

    /// Starts a return for `row`, if it has focus (`focused`), and returns the report its
    /// editor fills in; otherwise `nil`, and nothing is asked. `key` keys the list the way
    /// the host's `ForEach` does.
    static func request<Key: Hashable, Value: Equatable>(
        for row: KeyedRow<Key, Value>, focused: AnyHashable?,
        in state: Binding<RowFocusReturn?>, key: @escaping (Value) -> Key
    ) -> EditReport<Value>? {
        guard focused == AnyHashable(row.id) else { return nil }
        state.wrappedValue = RowFocusReturn()
        return EditReport(
            saved: { written in
                // An unchanged value leaves the row, and its focus, where they were.
                if written == row.element {
                    state.wrappedValue = nil
                } else {
                    state.wrappedValue?.stage = .saved
                }
            },
            committed: { written, list in
                guard state.wrappedValue?.stage == .saved else { return }
                let rows = (list ?? []).keyedRows(by: key)
                let matching = rows.filter { $0.id.key == key(written) }
                // Of equal rows, the one at the edited position.
                guard
                    let target = matching.first(where: { $0.index == row.index }) ?? matching.first
                else {
                    state.wrappedValue = nil  // The write found nothing to replace.
                    return
                }
                state.wrappedValue?.stage = .committed(AnyHashable(target.id))
            })
    }

    /// The sheet has finished closing. Closed without saving, there is nothing to return.
    static func sheetClosed(_ state: Binding<RowFocusReturn?>) {
        guard let current = state.wrappedValue else { return }
        if current.stage == .editing {
            state.wrappedValue = nil
        } else {
            state.wrappedValue?.sheetIsGone = true
        }
    }

    /// What the request does next, given the rows on screen.
    enum Outcome: Equatable {
        /// Keep waiting: for the save, the commit, the reload, or the sheet to close.
        case wait
        /// Focus this row, and the request is done.
        case focus(AnyHashable)
        /// Give up: the first new rows after the commit don't have the target (a later
        /// write removed it).
        case drop
    }

    /// The rule, apart from the view: focus the target once its row is on screen and the
    /// sheet is gone; drop it if the rows change after the commit without it.
    func outcome(rowIDs: [AnyHashable], rowsChanged: Bool) -> Outcome {
        guard case .committed(let target) = stage else { return .wait }
        if rowIDs.contains(target) { return sheetIsGone ? .focus(target) : .wait }
        return rowsChanged ? .drop : .wait
    }

    fileprivate static func settle(
        _ state: Binding<RowFocusReturn?>, rowIDs: [AnyHashable], rowsChanged: Bool,
        focus: FocusState<AnyHashable?>.Binding
    ) {
        switch state.wrappedValue?.outcome(rowIDs: rowIDs, rowsChanged: rowsChanged) {
        case .focus(let target):
            state.wrappedValue = nil
            // A turn later, so a row the reload just built is there to take focus.
            Task { focus.wrappedValue = target }
        case .drop:
            state.wrappedValue = nil
        case .wait, nil:
            break
        }
    }
}

/// Hosts a list's focus return: settles `state` whenever it moves or the rows change.
private struct RowFocusReturning: ViewModifier {
    let state: Binding<RowFocusReturn?>
    let rowIDs: [AnyHashable]
    let focus: FocusState<AnyHashable?>.Binding

    func body(content: Content) -> some View {
        content
            .onChange(of: state.wrappedValue) {
                RowFocusReturn.settle(state, rowIDs: rowIDs, rowsChanged: false, focus: focus)
            }
            .onChange(of: rowIDs) {
                RowFocusReturn.settle(state, rowIDs: rowIDs, rowsChanged: true, focus: focus)
            }
    }
}

extension View {
    /// Returns keyboard focus to a row of this list after its editor replaced it. `rowIDs`
    /// are the ids of the rows on screen, as their `ForEach` identifies them.
    func returnsRowFocus(
        _ state: Binding<RowFocusReturn?>, rowIDs: [AnyHashable],
        focus: FocusState<AnyHashable?>.Binding
    ) -> some View {
        modifier(RowFocusReturning(state: state, rowIDs: rowIDs, focus: focus))
    }

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
