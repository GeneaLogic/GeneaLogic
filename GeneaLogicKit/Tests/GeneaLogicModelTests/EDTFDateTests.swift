import GeneaLogicModel
import Testing

/// Parse + bounds + qualification coverage for `EDTFDate` (EDTF Level 0–1 subset).
struct EDTFDateTests {

    // MARK: - Level 0: reduced-precision dates

    @Test func parsesFullDate() {
        let d = EDTFDate.parse("1920-05-12")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 5, day: 12))
        #expect(d?.upperBound == EDTFBound(year: 1920, month: 5, day: 12))
        #expect(d?.qualification == EDTFDate.Qualification.none)
        #expect(d?.isInterval == false)
    }

    @Test func expandsYearMonthToWholeMonth() {
        let d = EDTFDate.parse("1920-05")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 5, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1920, month: 5, day: 31))
    }

    @Test func expandsYearToWholeYear() {
        let d = EDTFDate.parse("1920")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 1, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1920, month: 12, day: 31))
    }

    @Test func februaryLeapYearLastDay() {
        #expect(EDTFDate.parse("2000-02")?.upperBound == EDTFBound(year: 2000, month: 2, day: 29))
        #expect(EDTFDate.parse("1900-02")?.upperBound == EDTFBound(year: 1900, month: 2, day: 28))
        #expect(EDTFDate.parse("2004-02")?.upperBound == EDTFBound(year: 2004, month: 2, day: 29))
    }

    @Test func rejectsOutOfRangeMonthAndDay() {
        #expect(EDTFDate.parse("1920-13") == nil)
        #expect(EDTFDate.parse("1920-00") == nil)
        #expect(EDTFDate.parse("1920-02-30") == nil)
        #expect(EDTFDate.parse("1921-02-29") == nil)  // 1921 isn't a leap year
        #expect(EDTFDate.parse("1920-04-31") == nil)  // April has 30 days
    }

    // MARK: - Level 1: qualification

    @Test func approximateQualifier() {
        let d = EDTFDate.parse("1920~")
        #expect(d?.qualification == EDTFDate.Qualification.approximate)
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 1, day: 1))
    }

    @Test func uncertainQualifier() {
        #expect(EDTFDate.parse("1920?")?.qualification == EDTFDate.Qualification.uncertain)
    }

    @Test func approximateAndUncertainQualifier() {
        #expect(
            EDTFDate.parse("1920%")?.qualification
                == EDTFDate.Qualification.approximateAndUncertain)
    }

    // MARK: - Level 1: unspecified digits

    @Test func decadeUnspecifiedDigit() {
        let d = EDTFDate.parse("192X")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 1, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1929, month: 12, day: 31))
    }

    @Test func centuryUnspecifiedDigits() {
        let d = EDTFDate.parse("19XX")
        #expect(d?.lowerBound == EDTFBound(year: 1900, month: 1, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1999, month: 12, day: 31))
    }

    @Test func maskedMonth() {
        let d = EDTFDate.parse("1920-XX")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 1, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1920, month: 12, day: 31))
    }

    @Test func maskedDay() {
        let d = EDTFDate.parse("1920-05-XX")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 5, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1920, month: 5, day: 31))
    }

    @Test func explicitDayInMaskedMonthSpansTheYear() {
        // "the 5th of some month in 1920" → Jan 5 … Dec 5.
        let d = EDTFDate.parse("1920-XX-05")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 1, day: 5))
        #expect(d?.upperBound == EDTFBound(year: 1920, month: 12, day: 5))
    }

    @Test func maskedYearFebruary29ResolvesToInteriorLeapYears() {
        // 200X = 2000…2009; Feb 29 exists in 2000/2004/2008. The bounds are the
        // earliest and latest of those, not a rejection (the interval endpoints
        // 2000/2009 are leap/non-leap, so a naive "valid at both ends" check fails).
        let decade = EDTFDate.parse("200X-02-29")
        #expect(decade?.lowerBound == EDTFBound(year: 2000, month: 2, day: 29))
        #expect(decade?.upperBound == EDTFBound(year: 2008, month: 2, day: 29))
        // 199X = 1990…1999; both endpoints are non-leap, interior leaps are 1992/1996.
        let noLeapEnds = EDTFDate.parse("199X-02-29")
        #expect(noLeapEnds?.lowerBound == EDTFBound(year: 1992, month: 2, day: 29))
        #expect(noLeapEnds?.upperBound == EDTFBound(year: 1996, month: 2, day: 29))
        // A single non-leap year still rejects Feb 29 (no valid placement).
        #expect(EDTFDate.parse("1921-02-29") == nil)
    }

    // MARK: - Level 0/1: intervals

    @Test func closedInterval() {
        let d = EDTFDate.parse("1900/1905")
        #expect(d?.isInterval == true)
        #expect(d?.lowerBound == EDTFBound(year: 1900, month: 1, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1905, month: 12, day: 31))
    }

    @Test func intervalWithMonthPrecision() {
        let d = EDTFDate.parse("1920-03/1920-09")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 3, day: 1))
        #expect(d?.upperBound == EDTFBound(year: 1920, month: 9, day: 30))
    }

    @Test func openStartInterval() {
        // "../1950" — on or before 1950: unknown start, known end.
        let d = EDTFDate.parse("../1950")
        #expect(d?.lowerBound == nil)
        #expect(d?.upperBound == EDTFBound(year: 1950, month: 12, day: 31))
    }

    @Test func openEndInterval() {
        // "1920/.." — 1920 or later: known start, unknown end.
        let d = EDTFDate.parse("1920/..")
        #expect(d?.lowerBound == EDTFBound(year: 1920, month: 1, day: 1))
        #expect(d?.upperBound == nil)
    }

    @Test func emptySideOpenInterval() {
        // The bare-slash unknown forms are accepted as open too.
        #expect(EDTFDate.parse("1920/")?.upperBound == nil)
        #expect(EDTFDate.parse("/1920")?.lowerBound == nil)
    }

    @Test func rejectsFullyOpenAndMalformedIntervals() {
        #expect(EDTFDate.parse("../..") == nil)
        #expect(EDTFDate.parse("/") == nil)
        #expect(EDTFDate.parse("1900/1905/1910") == nil)
        #expect(EDTFDate.parse("1900/bogus") == nil)
    }

    // MARK: - Invalid input (kept as free text by callers)

    @Test func rejectsNonEDTF() {
        for bad in ["", "   ", "abt 1920", "spring 1920", "1920s", "192", "19200", "1920-5", "N/A"]
        {
            #expect(EDTFDate.parse(bad) == nil, "expected \(bad) to be rejected")
        }
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(
            EDTFDate.parse("  1920-05-12  ")?.lowerBound == EDTFBound(year: 1920, month: 5, day: 12)
        )
    }

    // MARK: - Bounds ordering

    @Test func boundOrdering() {
        #expect(EDTFBound(year: 1920, month: 1, day: 1) < EDTFBound(year: 1920, month: 1, day: 2))
        #expect(EDTFBound(year: 1919, month: 12, day: 31) < EDTFBound(year: 1920, month: 1, day: 1))
        #expect(EDTFBound(year: 1920, month: 5, day: 1) < EDTFBound(year: 1920, month: 6, day: 1))
    }

    @Test func sortBoundPrefersLowerElseUpper() {
        #expect(EDTFDate.parse("1920")?.sortBound == EDTFBound(year: 1920, month: 1, day: 1))
        // Open-start value sorts by its upper bound.
        #expect(EDTFDate.parse("../1950")?.sortBound == EDTFBound(year: 1950, month: 12, day: 31))
    }

    @Test func approximateSortsBeforeLaterExact() {
        // The bug lexicographic sort had: "1920~" must order before "1925".
        let approx = EDTFDate.parse("1920~")!.sortBound!
        let exact = EDTFDate.parse("1925")!.sortBound!
        #expect(approx < exact)
    }

    // MARK: - Year-range overlap (dateRange filtering)

    @Test func overlapSinglePartialDate() {
        #expect(EDTFDate.parse("1920")!.overlaps(years: 1915...1925))
        #expect(!EDTFDate.parse("1920")!.overlaps(years: 1921...1925))
    }

    @Test func overlapInterval() {
        let d = EDTFDate.parse("1900/1905")!
        #expect(d.overlaps(years: 1903...1910))  // overlaps the tail
        #expect(d.overlaps(years: 1890...1901))  // overlaps the head
        #expect(!d.overlaps(years: 1906...1910))  // wholly after
        #expect(!d.overlaps(years: 1890...1899))  // wholly before
    }

    @Test func overlapOpenBoundsAreUnbounded() {
        // "1920/.." (on or after 1920) overlaps any range reaching >= 1920.
        #expect(EDTFDate.parse("1920/..")!.overlaps(years: 1990...2000))
        #expect(!EDTFDate.parse("1920/..")!.overlaps(years: 1900...1919))
        // "../1950" (on or before 1950) overlaps any range reaching <= 1950.
        #expect(EDTFDate.parse("../1950")!.overlaps(years: 1800...1810))
        #expect(!EDTFDate.parse("../1950")!.overlaps(years: 1951...1960))
    }

    // MARK: - Human-readable rendering

    @Test func humanDescriptionReducedPrecision() {
        #expect(EDTFDate.parse("1920")?.humanDescription == "1920")
        #expect(EDTFDate.parse("1920-05")?.humanDescription == "May 1920")
        #expect(EDTFDate.parse("1920-05-12")?.humanDescription == "12 May 1920")
        #expect(EDTFDate.parse("1920-01-01")?.humanDescription == "1 January 1920")
    }

    @Test func humanDescriptionMaskedDigits() {
        #expect(EDTFDate.parse("192X")?.humanDescription == "1920s")
        #expect(EDTFDate.parse("190X")?.humanDescription == "1900s")
        // A century mask is kept distinct from the decade so both don't read "1900s".
        #expect(EDTFDate.parse("19XX")?.humanDescription == "20th century")
        #expect(EDTFDate.parse("18XX")?.humanDescription == "19th century")
        #expect(EDTFDate.parse("20XX")?.humanDescription == "21st century")
        #expect(EDTFDate.parse("1920-XX")?.humanDescription == "1920")
        #expect(EDTFDate.parse("1920-05-XX")?.humanDescription == "May 1920")
    }

    @Test func humanDescriptionQualifiers() {
        #expect(EDTFDate.parse("1920~")?.humanDescription == "about 1920")
        #expect(EDTFDate.parse("1920?")?.humanDescription == "1920?")
        #expect(EDTFDate.parse("1920%")?.humanDescription == "about 1920?")
        #expect(EDTFDate.parse("1920-05~")?.humanDescription == "about May 1920")
    }

    @Test func humanDescriptionIntervals() {
        #expect(EDTFDate.parse("1900/1905")?.humanDescription == "1900 to 1905")
        #expect(
            EDTFDate.parse("1920-03/1920-09")?.humanDescription == "March 1920 to September 1920")
        #expect(EDTFDate.parse("../1950")?.humanDescription == "on or before 1950")
        #expect(EDTFDate.parse("1920/..")?.humanDescription == "on or after 1920")
        #expect(EDTFDate.parse("1920/")?.humanDescription == "on or after 1920")
        #expect(EDTFDate.parse("/1920")?.humanDescription == "on or before 1920")
        // A qualifier on one interval endpoint globs the whole phrase.
        #expect(EDTFDate.parse("1900~/1905")?.humanDescription == "about 1900 to 1905")
    }

    // MARK: - Shorthand normalization

    @Test func normalizesApproximateShorthand() {
        for input in [
            "about 1920", "abt 1920", "abt. 1920", "circa 1920", "ca 1920", "ca. 1920", "c. 1920",
            "c 1920",
        ] {
            #expect(
                EDTFDate.normalizingShorthand(input) == "1920~",
                "expected \(input) → 1920~")
        }
        // Case-insensitive on the keyword; masked year survives (not lowercased).
        #expect(EDTFDate.normalizingShorthand("About 192X") == "192X~")
    }

    @Test func normalizesBeforeAfterShorthand() {
        #expect(EDTFDate.normalizingShorthand("before 1950") == "../1950")
        #expect(EDTFDate.normalizingShorthand("bef 1950") == "../1950")
        #expect(EDTFDate.normalizingShorthand("after 1920") == "1920/..")
        #expect(EDTFDate.normalizingShorthand("aft. 1920-05") == "1920-05/..")
    }

    @Test func normalizesRangeShorthand() {
        #expect(EDTFDate.normalizingShorthand("1900-1905") == "1900/1905")
        #expect(EDTFDate.normalizingShorthand("between 1900 and 1905") == "1900/1905")
        // Year-month and full dates are already EDTF — never split as a range.
        #expect(EDTFDate.normalizingShorthand("1920-05") == "1920-05")
        #expect(EDTFDate.normalizingShorthand("1920-05-12") == "1920-05-12")
    }

    @Test func normalizesMonthNameDates() {
        #expect(EDTFDate.normalizingShorthand("June 1920") == "1920-06")
        #expect(EDTFDate.normalizingShorthand("april 3, 1975") == "1975-04-03")
        #expect(EDTFDate.normalizingShorthand("3 April 1975") == "1975-04-03")
        #expect(EDTFDate.normalizingShorthand("May 3 1975") == "1975-05-03")  // no comma
        #expect(EDTFDate.normalizingShorthand("Sept 1920") == "1920-09")
        #expect(EDTFDate.normalizingShorthand("Jan. 1900") == "1900-01")
        // An invalid calendar day stays free text (the candidate fails `parse`).
        #expect(EDTFDate.normalizingShorthand("April 31, 1975") == "April 31, 1975")
        // Ambiguous all-numeric order is NOT interpreted.
        #expect(EDTFDate.normalizingShorthand("3 5 1975") == "3 5 1975")
    }

    @Test func normalizesLowercaseMask() {
        #expect(EDTFDate.normalizingShorthand("192x") == "192X")
        #expect(EDTFDate.normalizingShorthand("19xx") == "19XX")
        #expect(EDTFDate.normalizingShorthand("1920-05-xx") == "1920-05-XX")
        #expect(EDTFDate.normalizingShorthand("abt 192x") == "192X~")
    }

    @Test func normalizesDecadeShorthand() {
        // "1940s" → the masked decade "194X", which renders back to "1940s" (round-trips).
        #expect(EDTFDate.normalizingShorthand("1940s") == "194X")
        #expect(EDTFDate.normalizingShorthand("1900s") == "190X")
        #expect(EDTFDate.normalizingShorthand("1940's") == "194X")
        #expect(EDTFDate.parse(EDTFDate.normalizingShorthand("1940s"))?.humanDescription == "1940s")
        // A non-zero-ending year isn't a decade form — left as free text.
        #expect(EDTFDate.normalizingShorthand("1945s") == "1945s")
    }

    @Test func leavesUnrecognizedInputUnchanged() {
        for input in ["1920", "1920~", "spring 1920", "about the war", "c dog", "", "N/A"] {
            #expect(
                EDTFDate.normalizingShorthand(input) == input,
                "expected \(input) unchanged")
        }
    }

    @Test func normalizedShorthandThenParsesAndGlosses() {
        let normalized = EDTFDate.normalizingShorthand("abt 1920")
        #expect(EDTFDate.parse(normalized)?.humanDescription == "about 1920")
    }

    /// The core contract: a rewrite must always round-trip through `parse`. For every
    /// input, `normalizingShorthand` either returns it unchanged (kept as free text) or
    /// returns a string that parses — never a mangled unparseable value. Interval/range
    /// operands are the trap (a naive rule appends `~` to `1920/..` or splices a slash
    /// into a range), so they're exercised explicitly.
    @Test func normalizedShorthandAlwaysParsesOrIsUnchanged() {
        let inputs = [
            "abt 1920", "about 1920/..", "c 1920/", "before 1900/1905", "after ../1950",
            "between 1900/1901 and 1905", "between 1900 and 1905", "1900-1905", "1920-05",
            "spring 1920", "about the war", "", "1920~",
            "June 1920", "April 3, 1975", "3 April 1975", "April 31, 1975", "192x", "abt 192x",
            "1940s", "1900s", "1940's", "1945s",
        ]
        for input in inputs {
            let out = EDTFDate.normalizingShorthand(input)
            #expect(
                out == input || EDTFDate.parse(out) != nil,
                "\(input) → \(out): neither unchanged nor parseable")
        }
    }
}
