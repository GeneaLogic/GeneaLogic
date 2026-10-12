import GeneaLogicModel
import Testing

/// `SchemaVersion`'s comparison (slice 64, fork c): `major.minor` as integers, and
/// anything a build cannot parse compares as newer — fail closed.
@Suite struct SchemaVersionComparisonTests {

    @Test func theCurrentVersionParses() {
        #expect(SchemaVersion.parse(SchemaVersion.current) != nil)
    }

    @Test(arguments: [
        ("1.0", 1, 0), ("1.10", 1, 10), ("0.9", 0, 9), ("12.345", 12, 345), ("0.0", 0, 0),
    ])
    func parsesMajorMinor(_ text: String, _ major: Int, _ minor: Int) {
        let parsed = SchemaVersion.parse(text)
        #expect(parsed?.major == major)
        #expect(parsed?.minor == minor)
    }

    @Test(arguments: [
        "", "1", "1.", ".0", "1.0.0", "1.x", "v1.0", "1.0 ", " 1.0", "01.0", "1.00", "+1.0", "-1.0",
        "1.-0", "1,0",
    ])
    func rejectsWhatNoBuildWrites(_ text: String) {
        #expect(SchemaVersion.parse(text) == nil)
    }

    @Test func comparesAsIntegersNotStrings() {
        #expect(SchemaVersion.isNewer("1.10", than: "1.9"))
        #expect(!SchemaVersion.isNewer("1.9", than: "1.10"))
        #expect(SchemaVersion.isNewer("2.0", than: "1.99"))
        #expect(!SchemaVersion.isNewer("1.0", than: "1.0"))
        #expect(SchemaVersion.isNewer("1.0", than: "0.9"))
        #expect(!SchemaVersion.isNewer("0.9", than: "1.0"))
    }

    @Test func unparsableIsNewerThanAnythingParsable() {
        #expect(SchemaVersion.isNewer("next", than: "1.0"))
        #expect(!SchemaVersion.isNewer("1.0", than: "next"))
        #expect(SchemaVersion.isNewer("", than: "99.99"))
    }

    @Test func twoUnparsableVersionsAreNewerOnlyWhenTheyDiffer() {
        #expect(!SchemaVersion.isNewer("odd", than: "odd"))
        #expect(SchemaVersion.isNewer("odd", than: "odder"))
    }

    @Test func newerPicksTheLaterAndTiesGoToTheFirst() {
        #expect(SchemaVersion.newer("1.0", "1.1") == "1.1")
        #expect(SchemaVersion.newer("1.1", "1.0") == "1.1")
        #expect(SchemaVersion.newer("1.0", "1.0") == "1.0")
        #expect(SchemaVersion.newer("1.0", "next") == "next")
    }
}
