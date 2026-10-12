import Foundation

/// A mutated document and the words that say what was done to it, for the failure
/// message (slice 63, fork b).
public struct JSONMutant: Sendable, CustomStringConvertible {
    public let label: String
    public let bytes: Data
    public init(label: String, bytes: Data) {
        self.label = label
        self.bytes = bytes
    }
    public var description: String { label }
}

/// A valid document parsed once, with its sites enumerated once, so the mutants of
/// one value do not each re-parse it.
public struct JSONDocument: Sendable {
    public let bytes: Data
    public let tree: JSONNode
    public let sites: [[JSONNode.Step]]
    /// The sites that name an object member — the only ones a key can be dropped
    /// from or duplicated at.
    public let memberSites: [[JSONNode.Step]]

    public init(_ bytes: Data) throws {
        self.bytes = bytes
        self.tree = try JSONText.parse(bytes)
        self.sites = tree.sites
        self.memberSites = sites.filter {
            if case .member = $0.last { return true } else { return false }
        }
    }
}

/// Systematic damage to a valid JSON document. Two levels:
///
/// - **Bytes**: truncate, flip a bit, overwrite a burst — the shapes a torn write, a
///   bad sector or a sync provider's half-delivery produce. These need no parse.
/// - **Structure**: drop a member, duplicate a key, retype a value, put `null` where
///   a value is required, nest 100,000 deep, make a value absurdly long, or splice
///   invalid UTF-8 into a string — the shapes a buggy writer or a hostile one
///   produces. These go through `JSONText`, whose ordered object is what makes a
///   duplicate key expressible.
///
/// `exhaustive` enumerates every finite family completely; `random` draws one mutant
/// from one family for the sampled iterations of a property run.
public enum JSONMutator {

    /// What a value is replaced with under *retype*: every other JSON kind, plus the
    /// numbers a decoder has to think about.
    public static let retypeValues: [(label: String, value: JSONNode)] = [
        ("\"\"", .string("")), ("\"x\"", .string("x")),
        ("0", .number("0")), ("-1", .number("-1")), ("-0", .number("-0")),
        ("1e999", .number("1e999")), ("30-digit int", .number("999999999999999999999999999999")),
        ("true", .bool(true)), ("null", .null), ("[]", .array([])), ("{}", .object([])),
    ]

    /// Byte sequences that are not UTF-8, each spliced into a string value.
    public static let invalidUTF8: [(label: String, bytes: [UInt8])] = [
        ("truncated 2-byte", [0xC3, 0x28]),
        ("lone continuation", [0x80]),
        ("overlong solidus", [0xC0, 0xAF]),
        ("encoded surrogate", [0xED, 0xA0, 0x80]),
        ("5-byte lead", [0xF8, 0x88, 0x80, 0x80, 0x80]),
        ("0xFF", [0xFF]),
    ]

    public static let nestingDepth = 100_000
    public static let absurdStringLength = 1 << 20
    public static let absurdArrayLength = 10_000
    private static let absurdStringValue = String(repeating: "x", count: absurdStringLength)

    // MARK: - Exhaustive

    /// Every truncation offset, every member dropped, every member duplicated, every
    /// site retyped to every `retypeValues` entry — and one of each unbounded family
    /// (nesting, absurd length, each invalid UTF-8 sequence) at the first site.
    public static func exhaustive(_ json: Data) throws -> [JSONMutant] {
        try exhaustive(JSONDocument(json))
    }

    public static func exhaustive(_ document: JSONDocument) throws -> [JSONMutant] {
        let json = document.bytes
        let tree = document.tree
        var out: [JSONMutant] = []
        for offset in 0..<json.count {
            out.append(truncated(json, at: offset))
        }
        let sites = document.sites
        for site in sites {
            let name = tree.name(of: site)
            if case .member = site.last {
                out.append(dropped(tree, at: site, name: name))
                out.append(duplicated(tree, at: site, name: name))
            }
            for entry in retypeValues {
                out.append(retyped(tree, at: site, name: name, entry))
            }
        }
        if let first = sites.first {
            let name = tree.name(of: first)
            out.append(nestedArrays(tree, at: first, name: name))
            out.append(nestedObjects(tree, at: first, name: name))
            out.append(absurdString(tree, at: first, name: name))
            out.append(absurdArray(tree, at: first, name: name))
            for entry in invalidUTF8 {
                out.append(spliced(tree, at: first, name: name, entry))
            }
        }
        return out
    }

    // MARK: - Sampled

    /// One mutant from one family, chosen by `rng`.
    public static func random(_ json: Data, _ rng: inout SeededGenerator) throws -> JSONMutant {
        try random(JSONDocument(json), &rng)
    }

    /// The same, over a document parsed once — the form a property loop should use,
    /// since every mutant of one value shares its tree.
    public static func random(_ document: JSONDocument, _ rng: inout SeededGenerator)
        -> JSONMutant
    {
        let json = document.bytes
        let tree = document.tree
        let sites = document.sites
        guard let site = sites.randomElement(using: &rng) else {
            return truncated(json, at: Int.random(in: 0..<max(1, json.count), using: &rng))
        }
        let name = tree.name(of: site)
        let members = document.memberSites
        // Weighted: the unbounded families cost tens of milliseconds each to build
        // and say the same thing at every site, so they are rare here and covered by
        // `exhaustive` on the first iteration; the finite ones are the sample.
        switch Int.random(in: 0..<120, using: &rng) {
        case 0..<15:
            return truncated(json, at: Int.random(in: 0..<json.count, using: &rng))
        case 15..<30:
            return bitFlipped(json, &rng)
        case 30..<45:
            return burst(json, &rng)
        case 45..<60:
            let member = members.randomElement(using: &rng) ?? site
            return dropped(tree, at: member, name: tree.name(of: member))
        case 60..<75:
            let member = members.randomElement(using: &rng) ?? site
            return duplicated(tree, at: member, name: tree.name(of: member))
        case 75..<105:
            return retyped(tree, at: site, name: name, retypeValues.randomElement(using: &rng)!)
        case 105..<117:
            return spliced(tree, at: site, name: name, invalidUTF8.randomElement(using: &rng)!)
        case 117:
            return Bool.random(using: &rng)
                ? nestedArrays(tree, at: site, name: name)
                : nestedObjects(tree, at: site, name: name)
        case 118:
            return absurdString(tree, at: site, name: name)
        default:
            return absurdArray(tree, at: site, name: name)
        }
    }

    // MARK: - Byte families

    public static func truncated(_ json: Data, at offset: Int) -> JSONMutant {
        JSONMutant(label: "truncate at byte \(offset) of \(json.count)", bytes: json.prefix(offset))
    }

    public static func bitFlipped(_ json: Data, _ rng: inout SeededGenerator) -> JSONMutant {
        var bytes = json
        let offset = Int.random(in: 0..<bytes.count, using: &rng)
        let bit = Int.random(in: 0..<8, using: &rng)
        bytes[bytes.startIndex + offset] ^= UInt8(1 << bit)
        return JSONMutant(label: "flip bit \(bit) of byte \(offset)", bytes: bytes)
    }

    public static func burst(_ json: Data, _ rng: inout SeededGenerator) -> JSONMutant {
        var bytes = json
        let length = min(bytes.count, Int.random(in: 1...64, using: &rng))
        let offset = Int.random(in: 0...(bytes.count - length), using: &rng)
        for i in 0..<length {
            bytes[bytes.startIndex + offset + i] = UInt8.random(in: 0...255, using: &rng)
        }
        return JSONMutant(label: "overwrite \(length) bytes at \(offset)", bytes: bytes)
    }

    // MARK: - Structure families

    public static func dropped(_ tree: JSONNode, at site: [JSONNode.Step], name: String)
        -> JSONMutant
    {
        JSONMutant(label: "drop \(name)", bytes: JSONText.emit(tree.removing(at: site)))
    }

    /// The second copy holds a value of the same kind where one is easy to make —
    /// a different string for a string — so that which copy *wins* is observable
    /// (fork c), and `"duplicate"` otherwise.
    public static func duplicated(_ tree: JSONNode, at site: [JSONNode.Step], name: String)
        -> JSONMutant
    {
        let value: JSONNode
        switch tree[site] {
        case .string(let s): value = .string(s + "-duplicate")
        case .number: value = .number("7")
        case .bool(let b): value = .bool(!b)
        default: value = .string("duplicate")
        }
        return JSONMutant(
            label: "duplicate key \(name)",
            bytes: JSONText.emit(tree.duplicatingMember(at: site, with: value)))
    }

    public static func retyped(
        _ tree: JSONNode, at site: [JSONNode.Step], name: String,
        _ entry: (label: String, value: JSONNode)
    ) -> JSONMutant {
        JSONMutant(
            label: "retype \(name) to \(entry.label)",
            bytes: JSONText.emit(tree.replacing(at: site, with: entry.value)))
    }

    public static func nestedArrays(_ tree: JSONNode, at site: [JSONNode.Step], name: String)
        -> JSONMutant
    {
        let raw =
            Array(repeating: UInt8(ascii: "["), count: nestingDepth)
            + Array(repeating: UInt8(ascii: "]"), count: nestingDepth)
        return JSONMutant(
            label: "nest \(nestingDepth) arrays at \(name)",
            bytes: JSONText.emit(tree.replacing(at: site, with: .raw(raw))))
    }

    public static func nestedObjects(_ tree: JSONNode, at site: [JSONNode.Step], name: String)
        -> JSONMutant
    {
        var raw: [UInt8] = []
        let open = Array("{\"a\":".utf8)
        for _ in 0..<nestingDepth { raw.append(contentsOf: open) }
        raw.append(contentsOf: Array("null".utf8))
        raw.append(contentsOf: Array(repeating: UInt8(ascii: "}"), count: nestingDepth))
        return JSONMutant(
            label: "nest \(nestingDepth) objects at \(name)",
            bytes: JSONText.emit(tree.replacing(at: site, with: .raw(raw))))
    }

    public static func absurdString(_ tree: JSONNode, at site: [JSONNode.Step], name: String)
        -> JSONMutant
    {
        let value = JSONNode.string(absurdStringValue)
        return JSONMutant(
            label: "\(absurdStringLength)-byte string at \(name)",
            bytes: JSONText.emit(tree.replacing(at: site, with: value)))
    }

    public static func absurdArray(_ tree: JSONNode, at site: [JSONNode.Step], name: String)
        -> JSONMutant
    {
        let element = tree[site] ?? .null
        let value = JSONNode.array(Array(repeating: element, count: absurdArrayLength))
        return JSONMutant(
            label: "\(absurdArrayLength)-element array at \(name)",
            bytes: JSONText.emit(tree.replacing(at: site, with: value)))
    }

    public static func spliced(
        _ tree: JSONNode, at site: [JSONNode.Step], name: String,
        _ entry: (label: String, bytes: [UInt8])
    ) -> JSONMutant {
        let raw =
            [UInt8(ascii: "\"")] + Array("ab".utf8) + entry.bytes + Array("cd".utf8)
            + [UInt8(ascii: "\"")]
        return JSONMutant(
            label: "invalid UTF-8 (\(entry.label)) in a string at \(name)",
            bytes: JSONText.emit(tree.replacing(at: site, with: .raw(raw))))
    }
}
