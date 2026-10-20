import Foundation
import GeneaLogicModel
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
            localRef: "p2", nameAsRecorded: "Anna", role: .subject, informationQuality: .primary),
            PersonMention(
            localRef: "p3", nameAsRecorded: "Piotr", role: .subject, informationQuality: .primary),
        ]
        #expect(mentions.position(near: 2, where: { $0.localRef == "p3" }) == 1)
    }

    // MARK: Focus after an edit

    /// The usual order: the write is quick, so its reload lands while the sheet is still
    /// closing, and focus waits for the close.
    @Test func focusWaitsForTheSheetWhenTheReloadComesFirst() {
        var request: RowFocusReturn<Event>? = RowFocusReturn(key: death, hint: 1)
        let rows = [birth, death].keyedRows()
        #expect(RowFocusReturn.reloaded(&request, rows: rows) == nil)
        #expect(RowFocusReturn.sheetClosed(&request) == AnyHashable(rows[1].id))
        #expect(request == nil)
    }

    @Test func focusWaitsForTheReloadWhenTheSheetClosesFirst() {
        var request: RowFocusReturn<Event>? = RowFocusReturn(key: death, hint: 1)
        #expect(RowFocusReturn.sheetClosed(&request) == nil)
        let rows = [birth, death].keyedRows()
        #expect(RowFocusReturn.reloaded(&request, rows: rows) == AnyHashable(rows[1].id))
        #expect(request == nil)
    }

    /// Of two equal rows, focus goes to the one that was edited.
    @Test func focusPrefersTheEditedRowAmongEqualOnes() {
        var request: RowFocusReturn<Event>? = RowFocusReturn(key: birth, hint: 2)
        _ = RowFocusReturn.sheetClosed(&request)
        let rows = [birth, census, birth].keyedRows()
        #expect(RowFocusReturn.reloaded(&request, rows: rows) == AnyHashable(rows[2].id))
    }

    /// A write that found nothing to replace never brings its row in. The request is
    /// dropped, rather than left to fire on a later reload that happens to show the value.
    @Test func aWriteThatFoundNothingDropsTheRequest() {
        var request: RowFocusReturn<Event>? = RowFocusReturn(key: death, hint: 1)
        _ = RowFocusReturn.sheetClosed(&request)
        #expect(RowFocusReturn.reloaded(&request, rows: [birth].keyedRows()) == nil)
        #expect(request == nil)
    }
}
