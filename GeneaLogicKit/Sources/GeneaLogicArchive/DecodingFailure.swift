import Foundation

/// One line of plain words for a read or decode failure (slice 63, fork e).
///
/// `String(describing: DecodingError)` is a dump — `dataCorrupted(Swift.DecodingError
/// .Context(codingPath: [], debugDescription: …, underlyingError: Error
/// Domain=NSCocoaErrorDomain Code=3840 …))` — and it was the whole of what `open`
/// said about a corrupt `manifest.json`. This keeps the one fact each case carries
/// (which key, which path, what the parser choked on) and drops the rest.
enum DecodingFailure {
    static func summary(of error: any Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decoding {
        case .dataCorrupted(let context):
            let detail = parserDetail(context.underlyingError)
            if context.codingPath.isEmpty {
                // Not `debugDescription`: at the root it is always Foundation's
                // "The given data was not valid JSON", and on Linux, which
                // attaches no parser error at all, it would only say it twice.
                return "not valid JSON" + (detail.map { " (\($0))" } ?? "")
            }
            // At a key, a value's reason can be in the context alone, with no
            // underlying error (slice 71) — Foundation's "does not fit in
            // Int64" where its parser lets the number through. No manifest field
            // reaches this on today's toolchain (both parsers refuse such a
            // number at the root); it is kept so a value's reason is never the
            // part that is dropped.
            return "`\(path(context.codingPath))` is not a valid value"
                + ((detail ?? readable(context.debugDescription)).map { " (\($0))" } ?? "")
        case .keyNotFound(let key, let context):
            return "missing `\(path(context.codingPath + [key]))`"
        case .typeMismatch(_, let context):
            return "`\(path(context.codingPath))` has the wrong type"
        case .valueNotFound(_, let context):
            return "`\(path(context.codingPath))` is null"
        @unknown default:
            return decoding.localizedDescription
        }
    }

    /// `files[2].sha256` — the coding path as a reader would name it.
    private static func path(_ keys: [any CodingKey]) -> String {
        var out = ""
        for key in keys {
            if let index = key.intValue {
                out += "[\(index)]"
            } else {
                out += out.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return out.isEmpty ? "(root)" : out
    }

    /// The parser's own words, when Foundation attached them — "Unexpected end of
    /// file", "Unexpected character 'æ' around line 1, column 1" — lowercased at
    /// the front so it reads inside a sentence.
    private static func parserDetail(_ underlying: (any Error)?) -> String? {
        guard let underlying else { return nil }
        let info = (underlying as NSError).userInfo
        return readable(info["NSDebugDescription"] as? String)
    }

    /// Foundation's or the parser's sentence, fit to sit inside one of ours — or
    /// `nil` when there is none.
    private static func readable(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        // The parser quotes the byte it choked on, which for a binary file is a
        // control character — not something to put in an alert verbatim.
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? "\u{FFFD}" : scalar)
        }
        let cleaned = String(scalars)
        let trimmed = cleaned.hasSuffix(".") ? String(cleaned.dropLast()) : cleaned
        // Not an acronym: "ISO8601…" or "UUID…" keeps its capitals (`/code-review`).
        let second = trimmed.dropFirst().first
        if second?.isUppercase == true || second?.isNumber == true { return trimmed }
        return trimmed.prefix(1).lowercased() + trimmed.dropFirst()
    }
}
