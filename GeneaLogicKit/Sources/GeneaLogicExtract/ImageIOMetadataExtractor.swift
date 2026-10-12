import Foundation
import GeneaLogicModel

#if canImport(ImageIO)
import ImageIO

/// A `MetadataExtractor` that reads embedded EXIF/IPTC/XMP from image files via
/// ImageIO (Apple platforms only). See ARCHITECTURE.md §6.4.
///
/// Extraction is a pure function of the file's bytes: it opens the image,
/// reads its properties, and maps them into namespaced `EmbeddedMetadata`
/// entries (`exif:*`, `iptc:*`, `xmp:*`). Nothing here is ever written to a
/// genealogical field — the caller surfaces the result as a *suggestion*.
public struct ImageIOMetadataExtractor: MetadataExtractor {
    public init() {}

    public func extract(from url: URL) throws -> EmbeddedMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            // Not a recognizable image (or no properties) — no metadata is not
            // an error.
            return EmbeddedMetadata()
        }

        var entries: [EmbeddedMetadataKeyValue] = []

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            entries.append(contentsOf: mapEntries(exif, namespace: "exif"))
        }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            entries.append(contentsOf: mapEntries(iptc, namespace: "iptc"))
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            entries.append(contentsOf: mapEntries(gps, namespace: "gps"))
        }

        // ImageIO dictionary order isn't guaranteed; sort deterministically so
        // extraction is a pure, reproducible function (protocol requirement).
        entries.sort { lhs, rhs in
            lhs.key < rhs.key
        }

        return EmbeddedMetadata(entries: entries)
    }

    /// Maps a single ImageIO sub-dictionary (EXIF/IPTC/GPS) into namespaced
    /// `EmbeddedMetadataKeyValue` entries.
    private func mapEntries(_ dictionary: [CFString: Any], namespace: String)
        -> [EmbeddedMetadataKeyValue]
    {
        dictionary.map { key, value in
            EmbeddedMetadataKeyValue(
                key: EmbeddedMetadataKey(namespace: namespace, name: key as String),
                value: mapValue(value)
            )
        }
    }

    /// Maps a single ImageIO property value into an `EmbeddedMetadataValue`,
    /// preserving the rough shape (boolean / numeric / string) the protocol
    /// expects.
    private func mapValue(_ value: Any) -> EmbeddedMetadataValue {
        if let number = value as? NSNumber {
            // CFBoolean bridges to NSNumber; distinguish it from a genuine
            // numeric value by its Core Foundation type id (CFBoolean has its
            // own), so EXIF/IPTC flags map to `.boolean`, not `.number(1)`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        return .string(String(describing: value))
    }
}
#endif
