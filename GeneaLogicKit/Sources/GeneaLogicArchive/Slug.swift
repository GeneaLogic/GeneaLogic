import Foundation
import GeneaLogicModel

/// Filesystem-name sanitization and collision-free disambiguation
/// (ARCHITECTURE.md §4.2.1).
///
/// Two related but distinct jobs live here:
/// 1. **Slugging** — turning a human-readable string (an artifact title, a
///    person's name) into a friendly, filesystem-safe folder/file name. Slugs are
///    *non-authoritative* — identity is always the `uid` field.
/// 2. **Uniqueness & disambiguation** — given a desired sanitized name and a set
///    of names already in use, finding a collision-free variant. This is the
///    mechanism behind the `path`/`originalName` split for attached files.
enum Slug {
    /// Names reserved by convention and never assignable as a `path`/folder slug
    /// (ARCHITECTURE.md §3, §4.2.1): `record.json` inside an artifact folder, and
    /// `manifest.json` at the archive root. Comparison is case-folded (see
    /// `normalizedForComparison`) so `RECORD.JSON` etc. are caught too.
    static let reservedNames: Set<String> = ["record.json", "manifest.json"]

    /// Windows reserved device names (ARCHITECTURE.md §4.2.1: "avoided in case
    /// Windows is ever a target"), checked against the name with any extension
    /// stripped, case-insensitively.
    private static let windowsReservedStems: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    ]

    /// Maximum length, in Unicode scalars, of a sanitized stored name (filename
    /// or folder slug). 255 is the common filesystem limit (APFS, ext4, NTFS);
    /// kept comfortably under it to leave room for disambiguation suffixes
    /// (`-2`, `-<hash>`) without overflowing.
    private static let maxNameLength = 200

    // MARK: - Slug generation (folder / friendly names)

    /// Derives a friendly, filesystem-safe slug from free text (e.g. an
    /// artifact's title), suitable as a non-authoritative folder name like
    /// `artifacts/<slug>/`.
    ///
    /// This is intentionally simple: lowercase, ASCII-folded, whitespace and
    /// punctuation collapsed to single hyphens. It is NOT required to be unique —
    /// `makeUnique(_:against:)` handles that — and it is never the authoritative
    /// identity (the `uid` is).
    static func slugify(_ text: String, fallback: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
        let lowered = folded.lowercased()

        var result = ""
        result.reserveCapacity(lowered.count)
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let bounded = String(trimmed.prefix(maxNameLength))
        return bounded.isEmpty ? fallback : bounded
    }

    // MARK: - Sanitization (file basenames)

    /// Sanitizes a candidate file basename (the user's `originalName`) into a
    /// safe, writable name, per ARCHITECTURE.md §4.2.1: strips/replaces path
    /// separators and control characters, strips leading dots and trailing
    /// dots/spaces, enforces a length limit, and avoids Windows-reserved device
    /// names. This happens **before** any write — rejection/transformation never
    /// happens after the fact.
    ///
    /// This does not guarantee uniqueness; pair with `makeUnique(_:against:)`.
    static func sanitize(basename: String) -> String {
        // Split into stem + extension so we can re-append a safe extension after
        // trimming, and so reserved-device-name checks see the bare stem.
        let (stem, ext) = splitExtension(basename)

        var sanitizedStem = ""
        sanitizedStem.reserveCapacity(stem.count)
        for scalar in stem.unicodeScalars {
            switch scalar {
            case "/", "\\", ":":
                sanitizedStem.unicodeScalars.append("-")
            default:
                if scalar.properties.generalCategory == .control {
                    sanitizedStem.unicodeScalars.append("-")
                } else {
                    sanitizedStem.unicodeScalars.append(scalar)
                }
            }
        }

        // Strip leading dots (hidden-file convention) and trailing dots/spaces
        // (illegal/troublesome on Windows and easy to lose silently elsewhere).
        sanitizedStem = String(sanitizedStem.drop(while: { $0 == "." }))
        while let last = sanitizedStem.last, last == "." || last == " " {
            sanitizedStem.removeLast()
        }

        if sanitizedStem.isEmpty {
            sanitizedStem = "file"
        }

        if windowsReservedStems.contains(sanitizedStem.lowercased()) {
            sanitizedStem += "-file"
        }

        let sanitizedExt = ext.map { sanitizeExtension($0) }

        let assembled = joinStemAndExtension(stem: sanitizedStem, ext: sanitizedExt)

        // Normalize to NFC (mandatory for cross-platform safety; ARCHITECTURE.md §4.2.1).
        var normalized = assembled.precomposedStringWithCanonicalMapping

        // Enforce the overall length limit, trimming the stem (not the
        // extension, which carries semantic meaning for format detection).
        if normalized.count > maxNameLength {
            let extLength = sanitizedExt.map { $0.count + 1 } ?? 0  // +1 for the dot
            let allowedStemLength = max(1, maxNameLength - extLength)
            let trimmedStem = String(
                sanitizedStem.precomposedStringWithCanonicalMapping.prefix(allowedStemLength))
            normalized = joinStemAndExtension(stem: trimmedStem, ext: sanitizedExt)
        }

        return normalized
    }

    private static func sanitizeExtension(_ ext: String) -> String {
        var result = ""
        for scalar in ext.unicodeScalars {
            switch scalar {
            case "/", "\\", ":":
                continue
            default:
                if scalar.properties.generalCategory != .control {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    private static func joinStemAndExtension(stem: String, ext: String?) -> String {
        guard let ext, !ext.isEmpty else { return stem }
        return "\(stem).\(ext)"
    }

    /// Splits `name` into `(stem, extension)` at the last `.`, treating a
    /// leading-dot-only name (e.g. `".gitignore"`) as having no extension.
    private static func splitExtension(_ name: String) -> (stem: String, ext: String?) {
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
            return (name, nil)
        }
        let stem = String(name[name.startIndex..<dotIndex])
        let ext = String(name[name.index(after: dotIndex)...])
        return (stem, ext.isEmpty ? nil : ext)
    }

    // MARK: - Uniqueness & disambiguation

    /// The form of a name used for **collision comparison only**:
    /// case-folded and Unicode-NFC-normalized (ARCHITECTURE.md §4.2.1). This is
    /// mandatory for cross-platform safety — a case-sensitive Linux server could
    /// author `Scan.tif` and `scan.tif` side by side, which would collide the
    /// moment a case-insensitive APFS Mac opens the same archive; NFC/NFD accent
    /// variants are common in genealogical names and must collide too.
    ///
    /// This is purely a comparison key — the *stored* name keeps its
    /// human-chosen case and is normalized to NFC (not case-folded) by `sanitize`.
    static func normalizedForComparison(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folded
    }

    /// Returns `true` if `name` collides (under case-fold + NFC) with a reserved
    /// name (`record.json`, `manifest.json`).
    static func isReserved(_ name: String) -> Bool {
        let key = normalizedForComparison(name)
        return reservedNames.contains { normalizedForComparison($0) == key }
    }

    /// Given a sanitized candidate name and the set of names already present
    /// (compared case-fold + NFC), returns a collision-free variant.
    ///
    /// Disambiguation is deterministic: `name`, then `name-2`, `name-3`, … —
    /// inserted before the extension (`census-1920.tif` → `census-1920-2.tif`).
    /// This never silently overwrites; ARCHITECTURE.md §4.2.1 explicitly calls
    /// out `-2`/`-3`/a short content hash as acceptable schemes. We use the
    /// numeric suffix because it is simpler to reason about and test
    /// deterministically; a content-hash suffix would also work but would leak
    /// the sha256 into a place that isn't the canonical integrity surface.
    ///
    /// Reserved names (`record.json`, `manifest.json`) are treated as already
    /// "taken" so a candidate that sanitizes to one of them is disambiguated away
    /// from it rather than colliding with the convention-named file.
    static func makeUnique(
        _ candidate: String,
        against existingNames: some Sequence<String>
    ) -> String {
        makeUnique(
            candidate, againstNormalized: Set(existingNames.map(normalizedForComparison)),
            alsoTaken: { _ in false })
    }

    /// The same, with a second test a name must also pass — for a taken-ness the
    /// caller can only *probe* rather than list, such as what is on disk (slice
    /// 58b) — against names **already** in `normalizedForComparison` form, so a
    /// caller that tests more than one candidate normalizes its set once.
    static func makeUnique(
        _ candidate: String,
        againstNormalized taken: Set<String>,
        alsoTaken: (String) throws -> Bool
    ) rethrows -> String {
        guard try isTaken(candidate, againstNormalized: taken, alsoTaken: alsoTaken) else {
            return candidate
        }
        let (stem, ext) = splitExtension(candidate)
        var counter = 2
        while true {
            let attempt = joinStemAndExtension(stem: "\(stem)-\(counter)", ext: ext)
            if try !isTaken(attempt, againstNormalized: taken, alsoTaken: alsoTaken) {
                return attempt
            }
            counter += 1
        }
    }

    /// Whether `name` is reserved, in `taken` (already normalized), or taken by
    /// `alsoTaken` — the one test both `makeUnique` forms apply to each attempt.
    static func isTaken(
        _ name: String, againstNormalized taken: Set<String>,
        alsoTaken: (String) throws -> Bool
    ) rethrows -> Bool {
        try isReserved(name) || taken.contains(normalizedForComparison(name)) || alsoTaken(name)
    }
}

extension String {
    /// Case-folded form used for collision comparisons, paired with NFC
    /// normalization at the call site (`Slug.normalizedForComparison`).
    fileprivate var folded: String {
        folding(options: [.caseInsensitive], locale: .init(identifier: "en_US"))
    }
}
