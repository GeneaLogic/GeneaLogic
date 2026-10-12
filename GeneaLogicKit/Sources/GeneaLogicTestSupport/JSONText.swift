import Foundation

/// A JSON document as text, with an **ordered, duplicate-preserving** object — the
/// shape `JSONSerialization` cannot hold and slice 63's structure mutations need
/// (slice 63, fork b). Parsed from and emitted to bytes by this module's own
/// scanner, so a mutant can also carry bytes that are not JSON at all (`raw`).
public indirect enum JSONNode: Equatable, Sendable {
    case object([Member])
    case array([JSONNode])
    case string(String)
    /// The number's text, untouched: `-0`, `1e999` and a 30-digit integer are all
    /// numbers to the grammar and only a decoder decides what they are.
    case number(String)
    case bool(Bool)
    case null
    /// Emitted verbatim, unquoted. The one way to write invalid UTF-8 inside a
    /// string, or 100,000 nested brackets without recursing 100,000 deep here.
    case raw([UInt8])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONNode
        public init(key: String, value: JSONNode) {
            self.key = key
            self.value = value
        }
    }

    // MARK: - Sites

    /// One step from a node to a child: a member by position (not by key — keys
    /// can repeat) or an element by index.
    public enum Step: Equatable, Sendable, CustomStringConvertible {
        case member(Int)
        case element(Int)
        public var description: String {
            switch self {
            case .member(let i): return "m\(i)"
            case .element(let i): return "[\(i)]"
            }
        }
    }

    /// Every path to a value below the root, depth-first, members before their
    /// values' children. The root itself is not a site: replacing it is a different
    /// document, not a mutation of this one.
    public var sites: [[Step]] {
        var out: [[Step]] = []
        collectSites(prefix: [], into: &out)
        return out
    }

    private func collectSites(prefix: [Step], into out: inout [[Step]]) {
        switch self {
        case .object(let members):
            for (i, member) in members.enumerated() {
                let path = prefix + [.member(i)]
                out.append(path)
                member.value.collectSites(prefix: path, into: &out)
            }
        case .array(let elements):
            for (i, element) in elements.enumerated() {
                let path = prefix + [.element(i)]
                out.append(path)
                element.collectSites(prefix: path, into: &out)
            }
        default:
            break
        }
    }

    /// The value at `path`, or `nil` if the path does not exist.
    public subscript(path: [Step]) -> JSONNode? {
        guard let first = path.first else { return self }
        switch (self, first) {
        case (.object(let members), .member(let i)) where members.indices.contains(i):
            return members[i].value[Array(path.dropFirst())]
        case (.array(let elements), .element(let i)) where elements.indices.contains(i):
            return elements[i][Array(path.dropFirst())]
        default:
            return nil
        }
    }

    /// The readable name of a site: `events[0].date`, or `m3` for a nameless step.
    public func name(of path: [Step]) -> String {
        var node = self
        var out = ""
        for step in path {
            switch (node, step) {
            case (.object(let members), .member(let i)) where members.indices.contains(i):
                out += out.isEmpty ? members[i].key : ".\(members[i].key)"
                node = members[i].value
            case (.array(let elements), .element(let i)) where elements.indices.contains(i):
                out += "[\(i)]"
                node = elements[i]
            default:
                out += ".\(step)"
            }
        }
        return out
    }

    // MARK: - Edits

    /// `self` with the value at `path` replaced. A path that does not exist leaves
    /// the document unchanged.
    public func replacing(at path: [Step], with value: JSONNode) -> JSONNode {
        edit(at: path) { _ in .replace(value) }
    }

    /// `self` with the value at `path` removed (a member or an element).
    public func removing(at path: [Step]) -> JSONNode {
        edit(at: path) { _ in .remove }
    }

    /// `self` with a second copy of the member at `path` inserted directly after
    /// it, under the **same key**, holding `value`. Only members can be duplicated;
    /// an element path leaves the document unchanged.
    public func duplicatingMember(at path: [Step], with value: JSONNode) -> JSONNode {
        edit(at: path) { _ in .duplicate(value) }
    }

    private enum Edit {
        case replace(JSONNode)
        case remove
        case duplicate(JSONNode)
    }

    private func edit(at path: [Step], _ apply: (JSONNode) -> Edit) -> JSONNode {
        guard let first = path.first else { return self }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.object(var members), .member(let i)) where members.indices.contains(i):
            if rest.isEmpty {
                switch apply(members[i].value) {
                case .replace(let value): members[i].value = value
                case .remove: members.remove(at: i)
                case .duplicate(let value):
                    members.insert(Member(key: members[i].key, value: value), at: i + 1)
                }
            } else {
                members[i].value = members[i].value.edit(at: rest, apply)
            }
            return .object(members)
        case (.array(var elements), .element(let i)) where elements.indices.contains(i):
            if rest.isEmpty {
                switch apply(elements[i]) {
                case .replace(let value): elements[i] = value
                case .remove: elements.remove(at: i)
                case .duplicate: break
                }
            } else {
                elements[i] = elements[i].edit(at: rest, apply)
            }
            return .array(elements)
        default:
            return self
        }
    }
}

/// The scanner and emitter for `JSONNode`. Compact output, keys in the order given,
/// duplicates kept. Escapes what RFC 8259 requires (`"`, `\`, controls) and nothing
/// else, so a non-ASCII scalar is written as itself.
public enum JSONText {
    public struct ParseError: Error, CustomStringConvertible {
        public let offset: Int
        public let reason: String
        public var description: String { "\(reason) at byte \(offset)" }
    }

    // MARK: - Emit

    public static func emit(_ node: JSONNode) -> Data {
        var out: [UInt8] = []
        write(node, into: &out)
        return Data(out)
    }

    private static func write(_ node: JSONNode, into out: inout [UInt8]) {
        switch node {
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            for (i, member) in members.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                writeString(member.key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(member.value, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        case .array(let elements):
            out.append(UInt8(ascii: "["))
            for (i, element) in elements.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                write(element, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .string(let s):
            writeString(s, into: &out)
        case .number(let text):
            out.append(contentsOf: Array(text.utf8))
        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .raw(let bytes):
            out.append(contentsOf: bytes)
        }
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        // Fast path: nothing to escape, append the bytes wholesale.
        if !s.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }) {
            out.append(contentsOf: s.utf8)
            out.append(UInt8(ascii: "\""))
            return
        }
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: Array("\\\"".utf8))
            case UInt8(ascii: "\\"): out.append(contentsOf: Array("\\\\".utf8))
            case 0x0A: out.append(contentsOf: Array("\\n".utf8))
            case 0x0D: out.append(contentsOf: Array("\\r".utf8))
            case 0x09: out.append(contentsOf: Array("\\t".utf8))
            case 0x00..<0x20:
                out.append(contentsOf: Array(String(format: "\\u%04x", Int(byte)).utf8))
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    // MARK: - Parse

    public static func parse(_ data: Data) throws -> JSONNode {
        var parser = Parser(bytes: Array(data))
        let node = try parser.value()
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("trailing bytes") }
        return node
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool { index >= bytes.count }
        func error(_ reason: String) -> ParseError { ParseError(offset: index, reason: reason) }

        mutating func skipWhitespace() {
            while !atEnd, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard !atEnd, bytes[index] == byte else {
                throw error("expected '\(Character(UnicodeScalar(byte)))'")
            }
            index += 1
        }

        mutating func value() throws -> JSONNode {
            skipWhitespace()
            guard !atEnd else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard bytes.count - index >= expected.count,
                Array(bytes[index..<index + expected.count]) == expected
            else { throw error("expected \(word)") }
            index += expected.count
        }

        mutating func number() throws -> String {
            let start = index
            let numberBytes = Set("-+.eE0123456789".utf8)
            while !atEnd, numberBytes.contains(bytes[index]) { index += 1 }
            guard index > start else { throw error("unexpected byte") }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func object() throws -> JSONNode {
            try expect(UInt8(ascii: "{"))
            var members: [JSONNode.Member] = []
            skipWhitespace()
            if !atEnd, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                members.append(.init(key: key, value: try value()))
                skipWhitespace()
                guard !atEnd else { throw error("unexpected end in object") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "}"))
                return .object(members)
            }
        }

        mutating func array() throws -> JSONNode {
            try expect(UInt8(ascii: "["))
            var elements: [JSONNode] = []
            skipWhitespace()
            if !atEnd, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                elements.append(try value())
                skipWhitespace()
                guard !atEnd else { throw error("unexpected end in array") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "]"))
                return .array(elements)
            }
        }

        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            // Find the closing quote first (an escaped byte never closes), validate
            // the raw span as UTF-8 in one go, then resolve the escapes.
            let start = index
            while true {
                guard !atEnd else { throw error("unterminated string") }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { break }
                index += byte == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index <= bytes.count,
                let raw = String(validating: bytes[start..<index], as: UTF8.self)
            else {
                index = start
                throw error("invalid UTF-8 in string")
            }
            index += 1  // the closing quote
            var scalars = String.UnicodeScalarView()
            var iterator = raw.unicodeScalars.makeIterator()
            while let scalar = iterator.next() {
                guard scalar == "\\" else {
                    scalars.append(scalar)
                    continue
                }
                scalars.append(try escape(&iterator))
            }
            return String(scalars)
        }

        func escape(_ scalars: inout String.UnicodeScalarView.Iterator) throws
            -> Unicode.Scalar
        {
            guard let kind = scalars.next() else { throw error("unterminated escape") }
            switch kind {
            case "\"": return "\""
            case "\\": return "\\"
            case "/": return "/"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "u":
                let high = try hex4(&scalars)
                if (0xD800...0xDBFF).contains(high) {
                    guard scalars.next() == "\\", scalars.next() == "u" else {
                        throw error("lone high surrogate")
                    }
                    let low = try hex4(&scalars)
                    guard (0xDC00...0xDFFF).contains(low) else { throw error("bad surrogate") }
                    let value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    guard let scalar = Unicode.Scalar(value) else { throw error("bad scalar") }
                    return scalar
                }
                guard let scalar = Unicode.Scalar(high) else { throw error("bad scalar") }
                return scalar
            default:
                throw error("unknown escape")
            }
        }

        func hex4(_ scalars: inout String.UnicodeScalarView.Iterator) throws -> UInt32 {
            var text = ""
            for _ in 0..<4 {
                guard let scalar = scalars.next() else { throw error("bad \\u escape") }
                text.unicodeScalars.append(scalar)
            }
            guard let value = UInt32(text, radix: 16) else { throw error("bad \\u escape") }
            return value
        }
    }
}
