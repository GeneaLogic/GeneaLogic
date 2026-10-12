import GeneaLogicModel

/// Selects the platform-default `MetadataExtractor`, where one is available.
///
/// Keeps the platform `#if` in one place so callers (the app, the CLI) ask for
/// "the default extractor" without conditional compilation of their own.
public enum MetadataExtractors {
    /// The default extractor for the current platform, or `nil` where none
    /// exists yet.
    ///
    /// Apple platforms return ``ImageIOMetadataExtractor``. Linux returns `nil`
    /// until a libexif / pure-Swift conformer lands (ARCHITECTURE.md §6.4,
    /// ROADMAP, *Later*) — the Vapor server consumes processed snapshots and does
    /// not ingest raw files, so this is not yet a shared need.
    public static func makeDefault() -> (any MetadataExtractor)? {
        #if canImport(ImageIO)
        return ImageIOMetadataExtractor()
        #else
        return nil
        #endif
    }
}
