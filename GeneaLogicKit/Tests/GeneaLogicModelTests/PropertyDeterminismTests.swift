import GeneaLogicModel
import GeneaLogicTestSupport
import Testing

/// The same seed must produce the same values on macOS and Linux, or a failure the
/// Linux job reports cannot be reproduced on a Mac (slice 62, fork e). Two
/// layers are pinned:
///
/// 1. The generator itself, against SplitMix64's **published** test vectors for seed 0
///    — an external reference, so this is not the implementation agreeing with itself.
/// 2. One composed value, so the draw order of the generators above it is pinned too.
///    Changing a generator legitimately changes this; update the pin in the same
///    commit, which is the point — the change is then visible in review.
@Suite("Property determinism") struct PropertyDeterminismTests {

    @Test func splitMix64MatchesReferenceVectors() {
        var rng = SeededGenerator(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(rng.next() == 0x06C4_5D18_8009_454F)
    }

    @Test func iterationGeneratorsAreIndependentOfEachOther() {
        // Iteration 3 draws the same values whether or not 0–2 ran first — that is
        // what lets `GENEALOGIC_PROPERTY_ITERATIONS=4` reproduce a failure at 3.
        let run = PropertyRun(seed: 42, iterations: 4)
        var direct = PropertyRun.Iteration(seed: 42, index: 3).generator
        var viaLoop: UInt64?
        run.forEach { rng, iteration in
            if iteration.index == 3 { viaLoop = rng.next() }
        }
        #expect(viaLoop == direct.next())
    }

    @Test func composedValuesArePinned() {
        var rng = PropertyRun.Iteration(seed: PropertyRun.defaultSeed, index: 0).generator
        let id: ArtifactID = Gen.recordID(&rng, prefix: "ART")
        let word = Gen.word(&rng)
        let stamp = Gen.timestamp(&rng)
        #expect(id.raw == "ART-add7564f-0690-72ca-06e4-8103e82a0a6f")
        #expect(word == "Lo")
        #expect(stamp == "2003-02-03T05:27:33Z")
    }
}
