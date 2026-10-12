import GeneaLogicModel
import Testing

@testable import GeneaLogicMatch

/// What the archive's own place strings prove about place depth (slice 45o).
///
/// The strings throughout have the real corpus's shape, with its towns and addresses
/// swapped for the fictional family's (slice 74), because the rule was chosen against
/// them: two looser readings of "the archive proves this is a town" each look
/// reasonable in the abstract and each fail on a place string this archive actually
/// holds.
@Suite struct PlaceVocabularyTests {

    // MARK: - The rule

    /// The case the slice exists for: the archive writes `Rypin, Poland` somewhere, so
    /// a bare `Rypin` elsewhere is known not to be a country.
    @Test func aLeadingComponentOfAQualifiedPlaceIsProven() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Rypin, Poland"])

        #expect(vocabulary.isProvenSpecific("Rypin"))
    }

    /// And the value it was qualified *by* is not. This is the one that must never
    /// break: `Poland` is the most common bare place in the corpus, and promoting it
    /// would hand a country-level coincidence the corroborating weight slice 45n spent
    /// itself removing.
    @Test func aFinalComponentIsNotProven() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Rypin, Poland", "Sochaczew, Poland"])

        #expect(!vocabulary.isProvenSpecific("Poland"))
    }

    /// **Why the rule is *leading*, not *non-final*.** `NY` has something coarser above
    /// it in `Brooklyn, NY, USA`, so "any non-final component" — the first phrasing of
    /// this rule — would prove it a town and score two bare `NY` records at town
    /// strength. `Apt 4` is the same mistake with the joke removed.
    @Test(arguments: ["NY", "Apt 4"])
    func aMiddleComponentIsNotProven(value: String) {
        let vocabulary = PlaceVocabulary(placeStrings: [
            "Brooklyn, NY, USA",
            "87 Sackman Street, Apt 4, Brooklyn, NY",
        ])

        #expect(!vocabulary.isProvenSpecific(value))
    }

    /// **Why the rule is not *leading and never seen lower*.** `Brooklyn` leads
    /// `Brooklyn, NY` and sits mid-string in a street address — and it is a genuine
    /// town, the exact case this slice exists to rescue. So a value seen both ways
    /// resolves as **proven**: leading anywhere is proof, and a street address below it
    /// does not unprove it.
    @Test func aValueSeenBothWaysIsProven() {
        let vocabulary = PlaceVocabulary(placeStrings: [
            "Brooklyn, NY",
            "310 Hart Street, Brooklyn, NY",
        ])

        #expect(vocabulary.isProvenSpecific("Brooklyn"))
    }

    /// A single-component string is precisely the input whose depth is unknown, so it
    /// cannot be evidence about depth — including its own. Only qualified strings
    /// testify.
    @Test func aBarePlaceProvesNothingAboutItself() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Łomża", "Poland", "New York"])

        #expect(!vocabulary.isProvenSpecific("Łomża"))
    }

    /// The vocabulary is keyed on the same normalization every other comparison uses, so
    /// an American clerk's `Lomza` is answered by a Polish record's `Łomża`.
    @Test func normalizationApplies() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Łomża, Poland"])

        #expect(vocabulary.isProvenSpecific("lomza"))
        #expect(vocabulary.isProvenSpecific("ŁOMŻA"))
    }

    /// Order and repetition are irrelevant — it is a set, built from whatever the index
    /// hands over.
    @Test func theResultIsASet() {
        let once = PlaceVocabulary(placeStrings: ["Rypin, Poland"])
        let manyTimes = PlaceVocabulary(placeStrings: [
            "Rypin, Poland", "Rypin, Poland", "Rypin, Poland",
        ])

        #expect(once == manyTimes)
    }

    /// The empty vocabulary proves nothing, which is what makes it the honest default
    /// for a caller scoring outside any archive — and reproduces slice 45n exactly.
    @Test func theEmptyVocabularyProvesNothing() {
        #expect(!PlaceVocabulary.empty.isProvenSpecific("Rypin"))
        #expect(PlaceVocabulary(placeStrings: [String]()) == .empty)
    }

    /// Unusable strings contribute nothing rather than a phantom entry.
    @Test func unusableStringsContributeNothing() {
        #expect(PlaceVocabulary(placeStrings: ["", "   ", ",", ", ,"]) == .empty)
    }

    // MARK: - The real corpus, end to end

    /// Every place string in the real archive at the time of this slice (towns and addresses
    /// swapped for the fictional family's), and the whole vocabulary it yields. Pinned as a set
    /// because the promotion rule's blast radius on a real archive is the thing worth knowing: five
    /// towns, two street addresses, and **not one of the four values that archive actually records
    /// bare**.
    @Test func theRealCorpusYieldsTownsAndNoCountries() {
        let vocabulary = PlaceVocabulary(placeStrings: [
            // conclusions
            "Rypin, Poland", "Poland", "Brooklyn, NY, USA", "Brooklyn, NY",
            "Russia", "New York", "Charleston, SC, USA",
            // mentions and artifact locations
            "310 Hart Street, Brooklyn, NY", "Korostyshev, Russia", "Sochaczew, Poland",
            "87 Sackman Street, Apt 4, Brooklyn, NY", "29 Herzl Street, Brooklyn, NY",
        ])

        for town in ["Rypin", "Brooklyn", "Charleston", "Korostyshev", "Sochaczew"] {
            #expect(vocabulary.isProvenSpecific(town))
        }
        // The four bare values in that archive — none of them proven, so none of their
        // scores move. This is the tripwire test's premise, asserted at the source.
        for bare in ["Poland", "Russia", "New York", "NY"] {
            #expect(!vocabulary.isProvenSpecific(bare))
        }
    }
}
