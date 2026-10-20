import Foundation
import GeneaLogicModel
import SwiftUI
import Testing

@testable import GeneaLogicApp

/// Slice 79b — a row is identified by what it shows, and a write by the value its row
/// showed, so a mid-list delete or a shifted record can't hand one row's state, or one
/// row's edit, to another.
@MainActor
@Suite struct RowIdentityTests {

    private let birth = Event(type: "Birth", date: "1892")
    private let census = Event(type: "Census", date: "1900")
    private let death = Event(type: "Death", date: "1950")

    /// Two equal rows are still two rows: `ForEach` must never see one id twice.
    @Test func equalValuesGetDistinctIDs() {
        let rows = [birth, census, birth].keyedRows()
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows[0].id == RowKey(key: birth, occurrence: 0))
        #expect(rows[2].id == RowKey(key: birth, occurrence: 1))
        #expect(rows.map(\.index) == [0, 1, 2])
    }

    /// The finding: under `\.offset`, removing the first row gave the second row's slot
    /// to the third. Keyed by value, the survivors keep their own ids.
    @Test func removingAMidListRowLeavesTheOthersIDsAlone() {
        let before = [birth, census, death].keyedRows()
        let after = [birth, death].keyedRows()
        #expect(after.map(\.id) == [before[0].id, before[2].id])
    }

    /// Mentions are keyed by `localRef`, which an edit to the mention keeps.
    @Test func aMentionKeepsItsIDThroughAnEdit() {
        var mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Jan Kowal", role: .subject,
            informationQuality: .primary)
        let before = [mention].keyedRows(by: \.localRef)
        mention.nameAsRecorded = "Jan Kowalski"
        let after = [mention].keyedRows(by: \.localRef)
        #expect(before[0].id == after[0].id)
    }

    @Test func aWriteTakesTheHintWhenItStillMatches() {
        #expect([birth, census, birth].position(of: birth, near: 2) == 2)
    }

    /// The finding: an index still in range but pointing at another element removed the
    /// wrong one. The value check follows the element instead.
    @Test func aWriteFollowsAShiftedElement() {
        // The row drew `census` at 1; another writer has since removed `birth`.
        #expect([census, death].position(of: census, near: 1) == 0)
    }

    @Test func aWriteFindsNothingOnceTheElementIsGone() {
        #expect([birth, death].position(of: census, near: 1) == nil)
    }

    @Test func aMentionIsFoundByLocalRef() {
        let mentions = [
            PersonMention(
                localRef: "p2", nameAsRecorded: "Anna", role: .subject, informationQuality: .primary
            ),
            PersonMention(
                localRef: "p3", nameAsRecorded: "Piotr", role: .subject,
                informationQuality: .primary),
        ]
        #expect(mentions.position(near: 2, where: { $0.localRef == "p3" }) == 1)
    }

    // MARK: Focus after an edit

    /// Edits the second of `[birth, census]` from a focused row, as a host would: the
    /// request, its report for the editor, and the binding `@State` would give it.
    private func editCensus(
        focused: Bool = true
    ) -> (held: Held, report: EditReport<Event>?, ids: (Event...) -> [AnyHashable]) {
        let held = Held()
        let row = [birth, census].keyedRows()[1]
        let report = RowFocusReturn.request(
            for: row, focused: focused ? AnyHashable(row.id) : nil, in: held.binding,
            key: { $0 })
        return (held, report, { $0.keyedRows().map { AnyHashable($0.id) } })
    }

    /// The usual order: the write is quick, so its reload lands while the sheet is still
    /// closing, and focus waits for the close.
    @Test func focusWaitsForTheCloseWhenTheReloadComesFirst() throws {
        let (held, report, ids) = editCensus()
        report?.saved(death)
        report?.committed(death, [birth, death])
        let request = try #require(held.request)
        #expect(request.outcome(rowIDs: ids(birth, death), rowsChanged: true) == .wait)
        RowFocusReturn.sheetClosed(held.binding)
        #expect(
            held.request?.outcome(rowIDs: ids(birth, death), rowsChanged: false)
                == .focus(AnyHashable(RowKey(key: death, occurrence: 0))))
    }

    @Test func focusWaitsForTheReloadWhenTheCloseComesFirst() {
        let (held, report, ids) = editCensus()
        report?.saved(death)
        report?.committed(death, [birth, death])
        RowFocusReturn.sheetClosed(held.binding)
        #expect(held.request?.outcome(rowIDs: ids(birth, census), rowsChanged: false) == .wait)
        #expect(
            held.request?.outcome(rowIDs: ids(birth, death), rowsChanged: true)
                == .focus(AnyHashable(RowKey(key: death, occurrence: 0))))
    }

    /// The finding: a reload that lands before the write commits (it waited on the archive
    /// lock) doesn't have the new row yet. It must not answer the request.
    @Test func aReloadBeforeTheCommitDoesNotDropTheRequest() {
        let (held, report, ids) = editCensus()
        report?.saved(death)
        RowFocusReturn.sheetClosed(held.binding)
        #expect(held.request?.outcome(rowIDs: ids(birth), rowsChanged: true) == .wait)
        report?.committed(death, [birth, death])
        #expect(
            held.request?.outcome(rowIDs: ids(birth, death), rowsChanged: true)
                == .focus(AnyHashable(RowKey(key: death, occurrence: 0))))
    }

    /// The finding: a write that found nothing to replace changes nothing on screen, so no
    /// reload would ever answer it. The commit says so, and the request goes at once.
    @Test func aWriteThatFoundNothingAsksForNothing() {
        let (held, report, _) = editCensus()
        report?.saved(death)
        report?.committed(death, [birth])
        #expect(held.request == nil)
    }

    /// A later write removed the target before its reload: the first new rows answer it.
    @Test func rowsWithoutTheTargetAfterTheCommitDropIt() {
        let (held, report, ids) = editCensus()
        report?.saved(death)
        report?.committed(death, [birth, death])
        #expect(held.request?.outcome(rowIDs: ids(birth), rowsChanged: true) == .drop)
    }

    @Test func closingWithoutSavingAsksForNothing() {
        let (held, _, _) = editCensus()
        RowFocusReturn.sheetClosed(held.binding)
        #expect(held.request == nil)
    }

    /// An unchanged value leaves the row's view, and its focus, where they were.
    @Test func anUnchangedSaveAsksForNothing() {
        let (held, report, _) = editCensus()
        report?.saved(census)
        #expect(held.request == nil)
    }

    /// A mouse-opened edit gets no focus ring it didn't have.
    @Test func anUnfocusedRowAsksForNothing() {
        let (held, report, _) = editCensus(focused: false)
        #expect(report == nil)
        #expect(held.request == nil)
    }

    /// Of two equal rows, focus goes to the one that was edited.
    @Test func focusPrefersTheEditedRowAmongEqualOnes() {
        let held = Held()
        let row = [birth, census, birth].keyedRows()[2]
        let report = RowFocusReturn.request(
            for: row, focused: AnyHashable(row.id), in: held.binding, key: { $0 })
        report?.saved(census)
        report?.committed(census, [birth, census, census])
        RowFocusReturn.sheetClosed(held.binding)
        let ids = [birth, census, census].keyedRows().map { AnyHashable($0.id) }
        #expect(
            held.request?.outcome(rowIDs: ids, rowsChanged: true)
                == .focus(AnyHashable(RowKey(key: census, occurrence: 1))))
    }
}

/// A focus-return request held outside a view, the way `@State` holds it.
private final class Held {
    var request: RowFocusReturn?

    var binding: Binding<RowFocusReturn?> {
        Binding(get: { self.request }, set: { self.request = $0 })
    }
}
