/// A parsed Extended Date/Time Format (EDTF, ISO 8601-2 / Library of Congress)
/// value — the date grammar GeneaLogic uses for genealogical dates, which are
/// frequently approximate, uncertain, partial, or ranged.
///
/// Supports EDTF **Level 0** and the genealogically-relevant subset of **Level 1**:
///
/// - reduced-precision dates: `1920`, `1920-05`, `1920-05-12`
/// - intervals: `1900/1905`, `1920-03/1920-09`
/// - open / unknown interval ends: `../1950` ("on or before"), `1920/..` ("on or
///   after"); the bare `/` unknown form (`1920/`, `/1920`) is accepted as the same
/// - qualification: `1920~` (approximate), `1920?` (uncertain), `1920%` (both)
/// - unspecified digits: `192X` (a decade), `19XX` (a century span), `1920-XX`
///
/// **Not** supported (EDTF Level 2, rare in genealogy): sets (`{…}` / `[…]`),
/// seasons, per-component qualification, and letter-prefixed / negative years.
/// Such strings return `nil` from ``parse(_:)`` and callers treat the value as
/// free text.
///
/// EDTF is a strict superset of the ISO 8601 dates GeneaLogic previously used, so
/// every legacy `1920` / `1920-05-12` value is already a valid EDTF Level 0 date —
/// adopting EDTF widens the grammar without migrating any stored data.
///
/// The verbatim string stays authoritative (it is what's stored in `Event.date`);
/// this type is a **derived** projection used for chronological ordering
/// (``lowerBound`` / ``upperBound``) and date-range overlap, and is never itself
/// persisted. Human-readable rendering (e.g. "about 1920") is layered on at the
/// app level.
public struct EDTFDate: Equatable, Sendable {
    /// EDTF Level 1 date qualification.
    public enum Qualification: Equatable, Sendable {
        case none
        /// `~` — the date is an approximation (e.g. "about 1920").
        case approximate
        /// `?` — the date is uncertain (e.g. "1920, but doubted").
        case uncertain
        /// `%` — approximate *and* uncertain.
        case approximateAndUncertain
    }

    /// The string exactly as supplied to ``parse(_:)``.
    public let original: String

    /// Inclusive earliest instant the expression can denote, or `nil` for an
    /// open / unknown start (`../1950`). Used as the chronological sort key.
    public let lowerBound: EDTFBound?

    /// Inclusive latest instant the expression can denote, or `nil` for an open /
    /// unknown end (`1920/..`).
    public let upperBound: EDTFBound?

    public let qualification: Qualification

    /// Whether the value was written as an `X/Y` interval (as opposed to a single
    /// reduced-precision date, which also spans a range internally).
    public let isInterval: Bool

    /// Parses an EDTF Level 0–1 string, returning `nil` if it isn't valid EDTF in
    /// the supported subset (the caller then keeps it as unparsed free text). A
    /// nil/empty/whitespace-only input is not a valid date.
    public static func parse(_ string: String) -> EDTFDate? {
        let trimmed = string.trimmingCharactersInWhitespace()
        guard !trimmed.isEmpty else { return nil }

        if let slash = trimmed.firstIndex(of: "/") {
            let leftText = String(trimmed[trimmed.startIndex..<slash])
            let rightText = String(trimmed[trimmed.index(after: slash)...])
            // A second "/" means a set or an unsupported form — reject.
            guard !rightText.contains("/") else { return nil }

            guard let left = classifyEndpoint(leftText),
                let right = classifyEndpoint(rightText)
            else { return nil }
            let leftDate = left.component
            let rightDate = right.component
            // Both ends open (`../..`) denotes nothing usable — reject.
            guard leftDate != nil || rightDate != nil else { return nil }

            let qualification = Qualification.merge(
                leftDate?.qualification ?? .none, rightDate?.qualification ?? .none)
            return EDTFDate(
                original: string,
                lowerBound: leftDate?.lower,
                upperBound: rightDate?.upper,
                qualification: qualification,
                isInterval: true)
        }

        guard let component = parseComponent(trimmed) else { return nil }
        return EDTFDate(
            original: string,
            lowerBound: component.lower,
            upperBound: component.upper,
            qualification: component.qualification,
            isInterval: false)
    }

    // MARK: - Component parsing

    /// One side of an interval: an open / unknown marker, or a parsed date endpoint.
    private enum Endpoint {
        case open
        case date(ParsedComponent)

        /// The endpoint's date, or `nil` if it's the open marker.
        var component: ParsedComponent? {
            if case .date(let c) = self { return c }
            return nil
        }
    }

    /// Classifies one side of an interval: the open marker (`..` or an empty side),
    /// a valid date, or `nil` when the endpoint is malformed (rejecting the interval).
    private static func classifyEndpoint(_ text: String) -> Endpoint? {
        if text.isOpenMarker { return .open }
        guard let component = parseComponent(text) else { return nil }
        return .date(component)
    }

    private struct ParsedComponent: Equatable {
        let lower: EDTFBound
        let upper: EDTFBound
        let qualification: Qualification
    }

    /// Parses a single (non-interval) EDTF date: an optional trailing qualifier
    /// over `YYYY`, `YYYY-MM`, or `YYYY-MM-DD`, where any component may be masked
    /// with `X` unspecified digits. Expands reduced precision / masking into an
    /// inclusive `[lower, upper]` span.
    private static func parseComponent(_ text: String) -> ParsedComponent? {
        var body = Substring(text)
        var qualification = Qualification.none
        if let last = body.last, let q = qualifier(for: last) {
            qualification = q
            body = body.dropLast()
        }

        let parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }

        guard let years = parseYearField(parts[0]) else { return nil }
        // Month: present → parse; absent → the whole year (Jan…Dec).
        let months: ClosedRange<Int>
        if parts.count >= 2 {
            guard let m = parseMonthOrDay(parts[1], min: 1, max: 12) else { return nil }
            months = m
        } else {
            months = 1...12
        }

        // Day absent or masked (`XX`) → the whole month at each end. An explicit day is
        // placed at the earliest and latest `(year, month)` in the masked span where
        // it's a valid calendar day, so `200X-02-29` resolves to 2000-02-29…2008-02-29
        // (the leap years inside the decade) rather than being rejected.
        if parts.count >= 3, parts[2] != "XX" {
            guard let day = parseMonthOrDay(parts[2], min: 1, max: 31),
                day.lowerBound == day.upperBound,
                let bounds = placeExplicitDay(day.lowerBound, months: months, years: years)
            else { return nil }
            return ParsedComponent(
                lower: bounds.lower, upper: bounds.upper, qualification: qualification)
        }
        let lower = EDTFBound(year: years.lowerBound, month: months.lowerBound, day: 1)
        let upper = EDTFBound(
            year: years.upperBound, month: months.upperBound,
            day: daysIn(month: months.upperBound, year: years.upperBound))
        return ParsedComponent(lower: lower, upper: upper, qualification: qualification)
    }

    /// The earliest and latest `(year, month)` in the masked spans at which `day` is a
    /// valid calendar day, or `nil` if it's valid nowhere (e.g. `1921-02-29`). For a
    /// fully-specified date the two bounds collapse to the single day. The spans are
    /// small (≤ a century × 12 months), so the scan is cheap.
    private static func placeExplicitDay(
        _ day: Int, months: ClosedRange<Int>, years: ClosedRange<Int>
    ) -> (lower: EDTFBound, upper: EDTFBound)? {
        func firstValid<Y: Sequence<Int>, M: Sequence<Int>>(_ ys: Y, _ ms: M) -> EDTFBound? {
            for y in ys {
                for m in ms where day <= daysIn(month: m, year: y) {
                    return EDTFBound(year: y, month: m, day: day)
                }
            }
            return nil
        }
        guard let lower = firstValid(years, months),
            let upper = firstValid(years.reversed(), months.reversed())
        else { return nil }
        return (lower, upper)
    }

    /// Parses a 4-character year field, honoring `X` unspecified digits (`192X` →
    /// 1920…1929, `19XX` → 1900…1999). All-digit fields collapse to a single year.
    private static func parseYearField(_ field: String) -> ClosedRange<Int>? {
        guard field.count == 4 else { return nil }
        var lower = 0
        var upper = 0
        for ch in field {
            if ch.isASCIIDigit, let d = ch.wholeNumberValue {
                lower = lower * 10 + d
                upper = upper * 10 + d
            } else if ch == "X" {
                lower = lower * 10
                upper = upper * 10 + 9
            } else {
                return nil
            }
        }
        return lower...upper
    }

    /// Parses a 2-character month/day field, honoring `XX` masking (→ the full
    /// `min…max` span). Rejects out-of-range or partially-masked (`2X`) values.
    private static func parseMonthOrDay(_ field: String, min: Int, max: Int) -> ClosedRange<Int>? {
        guard field.count == 2 else { return nil }
        if field == "XX" { return min...max }
        // A single masked digit (e.g. `2X`) is Level 2 territory — reject for now.
        guard field.allSatisfy(\.isASCIIDigit), let value = Int(field), value >= min, value <= max
        else { return nil }
        return value...value
    }

    private static func qualifier(for ch: Character) -> Qualification? {
        switch ch {
        case "~": return .approximate
        case "?": return .uncertain
        case "%": return .approximateAndUncertain
        default: return nil
        }
    }

    /// Days in a Gregorian (proleptic) month, with leap-year handling for February.
    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}

extension EDTFDate {
    /// The chronological sort key: the earliest instant when known, else the latest
    /// (an open-start value like `../1950` sorts by its upper bound). Only `nil` if
    /// both bounds are `nil`, which ``parse(_:)`` never produces — so a parsed value
    /// always has a sort key.
    public var sortBound: EDTFBound? { lowerBound ?? upperBound }

    /// A human-readable gloss of the value, e.g. `"1920~"` → "about 1920",
    /// `"1900/1905"` → "1900 to 1905", `"../1950"` → "on or before 1950",
    /// `"192X"` → "1920s", `"1920-05-12"` → "12 May 1920".
    ///
    /// This is rendered from the source string's *structure* rather than from
    /// ``lowerBound`` / ``upperBound``, because the bounds discard precision (a plain
    /// `1920` and a masked decade `192X` both expand to a multi-day span, but read
    /// very differently). Day/month/year ordering follows the genealogy convention
    /// (`12 May 1920`, GEDCOM-style day-month-year — unambiguous and locale-free).
    public var humanDescription: String {
        let trimmed = original.trimmingCharactersInWhitespace()
        if isInterval, let slash = trimmed.firstIndex(of: "/") {
            let leftText = String(trimmed[trimmed.startIndex..<slash])
            let rightText = String(trimmed[trimmed.index(after: slash)...])
            let leftOpen = leftText.isOpenMarker
            let rightOpen = rightText.isOpenMarker
            // Open-ended intervals read best with the qualifier attached to the known
            // endpoint ("on or before about 1950"), not the whole phrase.
            if leftOpen && !rightOpen {
                return "on or before " + qualified(Self.renderComponent(rightText))
            }
            if rightOpen && !leftOpen {
                return "on or after " + qualified(Self.renderComponent(leftText))
            }
            // Both endpoints present (both-open is rejected by `parse`).
            return qualified(
                "\(Self.renderComponent(leftText)) to \(Self.renderComponent(rightText))")
        }
        return qualified(Self.renderComponent(trimmed))
    }

    /// Wraps a rendered phrase with its approximate/uncertain qualifier words.
    private func qualified(_ phrase: String) -> String {
        switch qualification {
        case .none: return phrase
        case .approximate: return "about \(phrase)"
        case .uncertain: return "\(phrase)?"
        case .approximateAndUncertain: return "about \(phrase)?"
        }
    }

    /// Renders one date component (`YYYY`, `YYYY-MM`, `YYYY-MM-DD`, with optional `X`
    /// masking and a trailing qualifier) to human text. Falls back to the raw text on
    /// anything unexpected (it only ever receives strings `parse` already accepted).
    private static func renderComponent(_ text: String) -> String {
        var body = Substring(text)
        if let last = body.last, last == "~" || last == "?" || last == "%" {
            body = body.dropLast()
        }
        let parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let yearField = parts.first else { return text }
        let yearText = renderYear(yearField)
        // Month absent or masked → year granularity.
        guard parts.count >= 2, parts[1] != "XX",
            let month = Int(parts[1]), (1...12).contains(month)
        else { return yearText }
        let monthName = monthNames[month - 1]
        // Day absent or masked → month granularity.
        guard parts.count >= 3, parts[2] != "XX", let day = Int(parts[2]) else {
            return "\(monthName) \(yearText)"
        }
        return "\(day) \(monthName) \(yearText)"
    }

    /// A 4-char year field to display text: a plain year verbatim (`1920`), a masked
    /// decade (`192X` → "1920s"), or a masked century (`19XX` → "20th century" — kept
    /// distinct from the decade so the two masks don't both read as "1900s"). Interior
    /// or otherwise unusual masks (`1X2X`) fall back to the raw field.
    private static func renderYear(_ field: String) -> String {
        guard field.count == 4 else { return field }
        if field.allSatisfy(\.isASCIIDigit) { return field }
        // Decade: three leading digits + a single masked ones place.
        if field.hasSuffix("X"), !field.hasSuffix("XX"), field.dropLast().allSatisfy(\.isASCIIDigit)
        {
            return String(field.dropLast()) + "0s"
        }
        // Century: two leading digits + "XX" (1900–1999 → the 20th century).
        if field.hasSuffix("XX"), field.prefix(2).allSatisfy(\.isASCIIDigit),
            let hundreds = Int(field.prefix(2))
        {
            return ordinal(hundreds + 1) + " century"
        }
        return field
    }

    /// An English ordinal (`20` → "20th", `21` → "21st"), for century rendering.
    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Rewrites common genealogist date shorthand to canonical EDTF, so a value the
    /// researcher naturally types (`"abt 1920"`, `"before 1950"`, `"1900-1905"`) is
    /// stored as EDTF (`"1920~"`, `"../1950"`, `"1900/1905"`) and thereafter parses,
    /// sorts, and glosses like any other date.
    ///
    /// Handles the common, unambiguous forms: qualifier words (`abt`/`about`/`c.`/`ca`/
    /// `circa`, `bef`/`before`, `aft`/`after`), ranges (`1900-1905`, `between … and …`),
    /// **month names** (`"June 1920"` → `"1920-06"`, `"April 3, 1975"` / `"3 April 1975"`
    /// → `"1975-04-03"`), and **lowercase masking** (`"192x"` → `"192X"`).
    ///
    /// Each rule builds a candidate EDTF string and is accepted **only if that candidate
    /// itself parses** — so a fired rule can never store an unparseable value (appending
    /// `~` to an open interval, splicing an interval operand into a range, or an invalid
    /// calendar day like `"April 31, 1975"` all fail this check and leave the input as
    /// free text). `"about the war"` / `"c dog"` / ambiguous all-numeric `"3 5 1975"` are
    /// likewise left untouched. Anything unrecognized is returned **unchanged**.
    public static func normalizingShorthand(_ input: String) -> String {
        let trimmed = input.trimmingCharactersInWhitespace()
        guard !trimmed.isEmpty else { return input }
        let lower = trimmed.lowercased()

        // Accept a rewrite only when it round-trips through `parse`; else keep free text.
        // A lowercase `x` masking digit is upcased to EDTF's `X` as part of the check, so
        // "192x"/"abt 192x" normalize like their uppercase forms.
        func accept(_ candidate: String) -> String {
            if parse(candidate) != nil { return candidate }
            let upcased = String(candidate.map { $0 == "x" ? "X" : $0 })
            if upcased != candidate, parse(upcased) != nil { return upcased }
            return input
        }

        // Approximate: "about 1920" / "abt 1920" / "circa 1920" / "ca. 1920" / "c 1920".
        for kw in ["about ", "abt. ", "abt ", "circa ", "ca. ", "ca ", "c. ", "c "]
        where lower.hasPrefix(kw) {
            let rest = String(trimmed.dropFirst(kw.count)).trimmingCharactersInWhitespace()
            return accept(rest + "~")
        }
        // Before: "before 1950" / "bef 1950" → "../1950".
        for kw in ["before ", "bef. ", "bef "] where lower.hasPrefix(kw) {
            let rest = String(trimmed.dropFirst(kw.count)).trimmingCharactersInWhitespace()
            return accept("../" + rest)
        }
        // After: "after 1920" / "aft 1920" → "1920/..".
        for kw in ["after ", "aft. ", "aft "] where lower.hasPrefix(kw) {
            let rest = String(trimmed.dropFirst(kw.count)).trimmingCharactersInWhitespace()
            return accept(rest + "/..")
        }
        // "between 1900 and 1905" → "1900/1905".
        let words = trimmed.split(separator: " ").map(String.init)
        if words.count == 4, words[0].lowercased() == "between", words[2].lowercased() == "and" {
            return accept("\(words[1])/\(words[3])")
        }
        // "1900-1905" (year-to-year) → "1900/1905". Only the NNNN-NNNN shape, so a
        // year-month ("1920-05") or full date ("1920-05-12") is left as valid EDTF.
        let dashed = trimmed.split(separator: "-", omittingEmptySubsequences: false).map(
            String.init)
        if dashed.count == 2, dashed[0].count == 4, dashed[1].count == 4 {
            return accept("\(dashed[0])/\(dashed[1])")
        }
        // Decade "1940s" (or "1940's") → "194X" — the EDTF masked decade, which itself
        // renders back to "1940s", so the value round-trips. Only a year ending in 0.
        if lower.hasSuffix("s") {
            var stem = String(trimmed.dropLast())
            if stem.hasSuffix("'") { stem = String(stem.dropLast()) }
            if stem.count == 4, stem.hasSuffix("0"), stem.allSatisfy(\.isASCIIDigit) {
                return accept(String(stem.dropLast()) + "X")
            }
        }
        // Month names: "June 1920" → "1920-06"; "April 3, 1975" / "3 April 1975" → "1975-04-03".
        // Tokens split on spaces and commas; `accept` validates the day against the month/year.
        if let ymd = monthNameDate(trimmed) { return accept(ymd) }

        // Fall through: return the input unchanged, except that a bare lowercase mask
        // ("192x") is rescued to canonical EDTF by `accept`'s x-upcasing.
        return accept(trimmed)
    }

    /// Interprets a month-name date — "June 1920", "April 3, 1975", or "3 April 1975" —
    /// as an EDTF `YYYY-MM` / `YYYY-MM-DD` string, or `nil` if the tokens don't form one.
    /// All-numeric input (e.g. "3 5 1975") is deliberately *not* interpreted: the
    /// month/day order would be ambiguous, so it's left as free text.
    private static func monthNameDate(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        func year(_ s: String) -> String? {
            s.count == 4 && s.allSatisfy(\.isASCIIDigit) ? s : nil
        }
        func day(_ s: String) -> Int? {
            guard (1...2).contains(s.count), s.allSatisfy(\.isASCIIDigit), let d = Int(s),
                (1...31).contains(d)
            else { return nil }
            return d
        }
        switch tokens.count {
        case 2:  // Month YYYY
            if let m = monthNumber(tokens[0]), let y = year(tokens[1]) {
                return "\(y)-\(pad2(m))"
            }
        case 3:  // Month D YYYY  or  D Month YYYY
            if let m = monthNumber(tokens[0]), let d = day(tokens[1]), let y = year(tokens[2]) {
                return "\(y)-\(pad2(m))-\(pad2(d))"
            }
            if let d = day(tokens[0]), let m = monthNumber(tokens[1]), let y = year(tokens[2]) {
                return "\(y)-\(pad2(m))-\(pad2(d))"
            }
        default:
            break
        }
        return nil
    }

    /// Maps an English month name or common abbreviation (case-insensitive, optional
    /// trailing `.`) to its number, or `nil`.
    private static func monthNumber(_ token: String) -> Int? {
        var key = token.lowercased()
        if key.hasSuffix(".") { key = String(key.dropLast()) }
        switch key {
        case "january", "jan": return 1
        case "february", "feb": return 2
        case "march", "mar": return 3
        case "april", "apr": return 4
        case "may": return 5
        case "june", "jun": return 6
        case "july", "jul": return 7
        case "august", "aug": return 8
        case "september", "sep", "sept": return 9
        case "october", "oct": return 10
        case "november", "nov": return 11
        case "december", "dec": return 12
        default: return nil
        }
    }

    /// Two-digit zero-padded string for a 1–12 / 1–31 value (Foundation-free).
    private static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// Whether the value's span overlaps an inclusive year range. Open bounds are
    /// treated as unbounded (an `../1950` overlaps any range ending at ≥ its year).
    /// Used for `dateRange` filtering.
    public func overlaps(years range: ClosedRange<Int>) -> Bool {
        let low = lowerBound?.year ?? Int.min
        let high = upperBound?.year ?? Int.max
        return low <= range.upperBound && high >= range.lowerBound
    }
}

/// An inclusive calendar bound (a `(year, month, day)` triple) produced by
/// expanding an EDTF value's precision. Ordered chronologically.
public struct EDTFBound: Comparable, Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: EDTFBound, rhs: EDTFBound) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension EDTFDate.Qualification {
    /// Combines two endpoints' qualifications: approximate/uncertain flags union.
    fileprivate static func merge(_ a: EDTFDate.Qualification, _ b: EDTFDate.Qualification)
        -> EDTFDate.Qualification
    {
        let approx = a.isApproximate || b.isApproximate
        let uncertain = a.isUncertain || b.isUncertain
        switch (approx, uncertain) {
        case (false, false): return .none
        case (true, false): return .approximate
        case (false, true): return .uncertain
        case (true, true): return .approximateAndUncertain
        }
    }

    fileprivate var isApproximate: Bool {
        self == .approximate || self == .approximateAndUncertain
    }
    fileprivate var isUncertain: Bool {
        self == .uncertain || self == .approximateAndUncertain
    }
}

// MARK: - String helpers (Foundation-free, Linux-safe)

extension String {
    /// Trims leading/trailing ASCII whitespace without importing Foundation.
    ///
    /// Module-internal (not `fileprivate`) because `OpenVocabulary.parsingLeniently`
    /// needs it too. Foundation *is* permitted in the model (CLAUDE.md bans only the
    /// UI frameworks); the point is narrower — `EDTFDate.swift`, `Enums.swift` and
    /// `Person.swift` are deliberately import-free, and reusing this keeps the rules
    /// added in slice 44c that way rather than pulling Foundation in for a trim.
    func trimmingCharactersInWhitespace() -> String {
        let ws: Set<Character> = [" ", "\t", "\n", "\r"]
        var chars = Substring(self)
        while let f = chars.first, ws.contains(f) { chars = chars.dropFirst() }
        while let l = chars.last, ws.contains(l) { chars = chars.dropLast() }
        return String(chars)
    }

    /// Whether this interval endpoint denotes an open / unknown bound: EDTF's `..`
    /// marker, or an empty side (`1920/`, `/1920`).
    fileprivate var isOpenMarker: Bool { isEmpty || self == ".." }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
