import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// A string carrying a NUL survives the index whole (slice 63, fork g).
/// `sqlite3_bind_text` with a length of `-1` reads to the first NUL, and
/// `String(cString:)` stops there too — so a place or a payload path with `\u{0}` in
/// it was indexed cut short, and the `file` table feeds the manifest recompute. The
/// format stores `\u{0}` verbatim (62), so the index has to as well.
@Suite struct NULInIndexedStringTests {

    private static let withNUL = "Sier\u{0}pc, Poland"

    @Test func boundTextRoundTripsThroughSQLite() throws {
        let root = TestSupport.makeTempDirectory()
        let db = try SQLiteDatabase(at: root.appendingPathComponent("t.sqlite"))
        try db.exec("CREATE TABLE t (v TEXT NOT NULL);")
        let insert = try db.prepare("INSERT INTO t (v) VALUES (?);")
        try db.bind(Self.withNUL, at: 1, on: insert)
        try db.run(insert)

        // `length()` on TEXT counts to the first NUL by SQLite's own definition;
        // the blob length is what says how many bytes were actually stored.
        let select = try db.prepare("SELECT v, length(CAST(v AS BLOB)) FROM t;")
        var value = ""
        var storedLength: Int64 = -1
        try db.query(select) { row in
            value = db.columnText(row, 0)
            storedLength = db.columnInt64(row, 1)
        }
        #expect(value.unicodeScalars.elementsEqual(Self.withNUL.unicodeScalars))
        #expect(storedLength == Int64(Self.withNUL.utf8.count))
    }

    @Test func placeWithNULIsIndexedWhole() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(
            .sample(locations: [Location(asRecorded: Self.withNUL, normalized: nil)]))
        let places = archive.withIndex { try? $0.allPlaceStrings() } ?? []
        #expect(places.count == 1)
        #expect(places.first?.unicodeScalars.elementsEqual(Self.withNUL.unicodeScalars) == true)
    }
}
