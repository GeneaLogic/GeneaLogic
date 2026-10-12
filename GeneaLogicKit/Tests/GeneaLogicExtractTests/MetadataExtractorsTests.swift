import GeneaLogicModel
import Testing

@testable import GeneaLogicExtract

/// Placeholder so the target compiles on both platforms; real fixture-based
/// ImageIO extraction tests are added alongside the slice-2 implementation
/// (and must be `#if canImport(ImageIO)`-guarded, since the extractor type
/// only exists on Apple platforms).
@Suite struct MetadataExtractorsTests {
    @Test func defaultExtractorAvailabilityMatchesPlatform() {
        let extractor = MetadataExtractors.makeDefault()
        #if canImport(ImageIO)
        #expect(extractor != nil)
        #else
        #expect(extractor == nil)
        #endif
    }
}
