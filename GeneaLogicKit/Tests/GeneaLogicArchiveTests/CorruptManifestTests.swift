import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// What `open` says about a `manifest.json` it cannot read (slice 63, fork
/// e). There is no skip path — the manifest is the archive's ledger — so the message
/// is the whole of the engine's help: a one-line reason in plain words, then what is
/// still true and where the file can come from.
@Suite struct CorruptManifestTests {

    private func message(afterWriting bytes: Data) throws -> String {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "One"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        try bytes.write(to: manifestURL)
        do {
            _ = try Archive.open(at: root)
            Issue.record("open succeeded on a manifest that should not decode")
            return ""
        } catch let error as ArchiveError {
            guard case .corruptManifest = error else {
                Issue.record("threw \(error), not corruptManifest")
                return ""
            }
            return error.description
        }
    }

    @Test func truncatedManifestSaysNotValidJSON() throws {
        let text = try message(afterWriting: Data(#"{"archiveUID":"x","files":[{"#.utf8))
        #expect(text.contains("manifest.json in "))
        #expect(text.contains("could not be read: not valid JSON"))
        #expect(text.contains("The archive's records are untouched"))
        #expect(text.contains("restore manifest.json from a backup or another copy"))
        #expect(!text.contains("DecodingError"), "no error dump: \(text)")
        #expect(!text.contains("Context("), "no error dump: \(text)")
    }

    @Test func missingKeyIsNamed() throws {
        let text = try message(afterWriting: Data(#"{"archiveUID":"x","files":[]}"#.utf8))
        #expect(text.contains("could not be read: missing `schemaVersion`"))
    }

    @Test func wrongTypeIsNamedWithItsPath() throws {
        let text = try message(
            afterWriting: Data(
                #"{"archiveUID":"x","schemaVersion":"1.0","updatedAt":"t","files":[{"path":"a","sha256":"b","byteLength":"nope"}]}"#
                    .utf8))
        #expect(text.contains("could not be read: `files[0].byteLength` has the wrong type"))
    }

    @Test func nullForRequiredValueIsNamed() throws {
        let text = try message(
            afterWriting: Data(
                #"{"archiveUID":null,"schemaVersion":"1.0","updatedAt":"t","files":[]}"#.utf8))
        #expect(text.contains("could not be read: `archiveUID` is null"))
    }

    /// A value's reason that Foundation (or our own decoder) gives only in the
    /// context, with no underlying error, is said rather than dropped (slice
    /// 71). Built by hand: on this toolchain both platforms' parsers reject an
    /// overflowing `byteLength` at the root, so no manifest reaches it.
    @Test func aReasonInTheContextAloneIsSaid() {
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int?
            init(stringValue: String) { self.stringValue = stringValue }
            init(intValue: Int) {
                self.stringValue = "\(intValue)"
                self.intValue = intValue
            }
        }
        let error = DecodingError.dataCorrupted(
            .init(
                codingPath: [Key(stringValue: "files"), Key(intValue: 0), Key(stringValue: "byteLength")],
                debugDescription: "Parsed JSON number <123456789012345678901234567890> does not fit in Int64."))
        #expect(
            DecodingFailure.summary(of: error)
                == "`files[0].byteLength` is not a valid value (parsed JSON number "
                + "<123456789012345678901234567890> does not fit in Int64)")
    }

    /// An acronym at the front keeps its capitals when the reason is put inside
    /// the sentence (`/code-review`).
    @Test func anAcronymIsNotLowercased() {
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        let error = DecodingError.dataCorrupted(
            .init(
                codingPath: [Key(stringValue: "updatedAt")],
                debugDescription: "ISO8601 date expected."))
        #expect(
            DecodingFailure.summary(of: error)
                == "`updatedAt` is not a valid value (ISO8601 date expected)")
    }

    /// At the root the context only ever says "The given data was not valid
    /// JSON" — and Linux attaches no parser detail at all — so it is not added.
    @Test func anOverflowingNumberIsNotValidJSONSaidOnce() throws {
        let text = try message(
            afterWriting: Data(
                #"{"archiveUID":"x","schemaVersion":"1.0","updatedAt":"t","files":[{"path":"a","sha256":"b","byteLength":9223372036854775808}]}"#
                    .utf8))
        #expect(text.contains("could not be read: not valid JSON"))
        #expect(!text.contains("given data"), "said twice: \(text)")
    }

    /// A binary file makes the parser quote the byte it stopped at; a control
    /// character must not reach an alert as itself.
    @Test func controlCharactersDoNotReachTheMessage() throws {
        let text = try message(afterWriting: Data([0x18, 0x00, 0x7F, 0x01]))
        #expect(text.contains("could not be read: not valid JSON"))
        #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    @Test func summaryOfANonDecodingErrorIsItsDescription() {
        struct Plain: Error, LocalizedError {
            var errorDescription: String? { "disk on fire" }
        }
        #expect(DecodingFailure.summary(of: Plain()) == "disk on fire")
    }
}
