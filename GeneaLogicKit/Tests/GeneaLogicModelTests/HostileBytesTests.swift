import Foundation
import GeneaLogicModel
import GeneaLogicTestSupport
import Testing

/// Hostile bytes must not be a crash (slice 63, forks a–c).
///
/// 62 proved the decoder over the space of *valid* values; this walks the space of
/// damaged ones. Every generated value is encoded and then mutated — truncated at
/// every offset, bit-flipped, a key dropped or duplicated, a value retyped, nested
/// 100,000 deep, made absurdly long, or spliced with invalid UTF-8 — and the decoder
/// is handed the result. The contract is three things (fork a):
///
/// 1. **No trap.** The process survives. A trap here takes the whole test run down,
///    which is loud by construction.
/// 2. **Bounded time.** The suite carries a time limit; a hang fails.
/// 3. **A decoded value is a well-formed one.** Whatever decodes from damaged bytes
///    must satisfy 62's properties — re-encode without throwing, decode back equal,
///    byte-stable — so garbage in never yields a value the format cannot write back.
///
/// "Decodes or throws" on its own is vacuous in Swift; (3) is what makes the
/// property say something. Finite families run exhaustively on iteration 0 of each
/// type and are sampled under `PropertyRun`'s budget after that.
@Suite("Hostile bytes", .timeLimit(.minutes(5))) struct HostileBytesTests {

    /// Sampled mutants per iteration after the exhaustive first one.
    private static let sampledPerIteration = 8

    private static func checkSurvival<T: Codable & Equatable & Arbitrary>(
        _ type: T.Type, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        PropertyRun.fromEnvironment.forEach { rng, iteration in
            do {
                let document = try JSONDocument(
                    try GeneaLogicJSON.encoder.encode(T.arbitrary(&rng)))
                let mutants: [JSONMutant]
                if iteration.index == 0 {
                    mutants = try JSONMutator.exhaustive(document)
                } else {
                    mutants = (0..<sampledPerIteration).map { _ in
                        JSONMutator.random(document, &rng)
                    }
                }
                for mutant in mutants {
                    survive(T.self, mutant, iteration, sourceLocation: sourceLocation)
                }
            } catch {
                Issue.record(
                    "\(T.self): could not build mutants — \(error) — \(iteration)",
                    sourceLocation: sourceLocation)
            }
        }
    }

    private static func survive<T: Codable & Equatable>(
        _ type: T.Type, _ mutant: JSONMutant, _ iteration: PropertyRun.Iteration,
        sourceLocation: SourceLocation
    ) {
        let decoded: T
        do {
            decoded = try GeneaLogicJSON.decoder.decode(T.self, from: mutant.bytes)
        } catch {
            return  // Throwing is the contract.
        }
        do {
            let reEncoded = try GeneaLogicJSON.encoder.encode(decoded)
            let again = try GeneaLogicJSON.decoder.decode(T.self, from: reEncoded)
            #expect(
                again == decoded,
                "\(T.self) decoded from [\(mutant)] does not round-trip — \(iteration)",
                sourceLocation: sourceLocation)
            #expect(
                try GeneaLogicJSON.encoder.encode(again) == reEncoded,
                "\(T.self) decoded from [\(mutant)] is not byte-stable — \(iteration)",
                sourceLocation: sourceLocation)
        } catch {
            let message =
                "\(T.self) decoded [\(mutant)] to a value the format cannot write back: "
                + "\(error) — \(iteration)"
            Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
        }
    }

    // MARK: - One test per persisted type, so a failure names it

    @Test func artifact() { Self.checkSurvival(Artifact.self) }
    @Test func person() { Self.checkSurvival(Person.self) }
    @Test func relationship() { Self.checkSurvival(Relationship.self) }
    @Test func evidenceLink() { Self.checkSurvival(EvidenceLink.self) }
    @Test func dismissal() { Self.checkSurvival(Dismissal.self) }
    @Test func manifest() { Self.checkSurvival(Manifest.self) }
    @Test func trashEntry() { Self.checkSurvival(TrashEntry.self) }

    @Test func personMention() { Self.checkSurvival(PersonMention.self) }
    @Test func recordedFact() { Self.checkSurvival(RecordedFact.self) }
    @Test func mentionRelationship() { Self.checkSurvival(MentionRelationship.self) }
    @Test func fileEntry() { Self.checkSurvival(FileEntry.self) }
    @Test func event() { Self.checkSurvival(Event.self) }
    @Test func location() { Self.checkSurvival(Location.self) }
    @Test func retrieval() { Self.checkSurvival(Retrieval.self) }
    @Test func externalIdentifier() { Self.checkSurvival(ExternalIdentifier.self) }
    @Test func provenance() { Self.checkSurvival(Provenance.self) }
    @Test func personName() { Self.checkSurvival(PersonName.self) }
    @Test func personFact() { Self.checkSurvival(PersonFact.self) }
    @Test func matchDimension() { Self.checkSurvival(MatchDimension.self) }
    @Test func matchBreakdown() { Self.checkSurvival(MatchBreakdown.self) }
    @Test func manifestEntry() { Self.checkSurvival(ManifestEntry.self) }

    // MARK: - Fork c: duplicate keys are pinned

    /// The **first** of two members under one key wins. Measured on macOS, asserted
    /// on both platforms (62e's rule) — not because first-wins is *right*, but so a
    /// Foundation that changes its mind is visible here rather than in an archive.
    @Test func firstDuplicateKeyWins() throws {
        let bytes = Data(#"{"asRecorded":"first","asRecorded":"second"}"#.utf8)
        let location = try GeneaLogicJSON.decoder.decode(Location.self, from: bytes)
        #expect(location.asRecorded == "first")

        // And through the mutator, over generated values: the copy it inserts comes
        // *after* the original, so the original must be what decodes.
        PropertyRun.fromEnvironment.forEach { rng, iteration in
            let event = Event.arbitrary(&rng)
            let encoded = try! GeneaLogicJSON.encoder.encode(event)
            let tree = try! JSONText.parse(encoded)
            for site in tree.sites where tree.name(of: site) == "type" {
                let mutant = JSONMutator.duplicated(tree, at: site, name: "type")
                let decoded = try? GeneaLogicJSON.decoder.decode(Event.self, from: mutant.bytes)
                #expect(
                    decoded?.type.unicodeScalars.elementsEqual(event.type.unicodeScalars) == true,
                    "a later duplicate of `type` won — \(iteration)")
            }
        }
    }

    // MARK: - The mutator is not vacuous

    /// The emitter's output is JSON the decoder reads to the same value; otherwise
    /// every structure mutant would throw for the emitter's reasons and the property
    /// above would pass by saying nothing.
    @Test func parseEmitRoundTripsThroughTheDecoder() throws {
        PropertyRun.fromEnvironment.forEach { rng, iteration in
            let artifact = Artifact.arbitrary(&rng)
            do {
                let encoded = try GeneaLogicJSON.encoder.encode(artifact)
                let emitted = JSONText.emit(try JSONText.parse(encoded))
                let decoded = try GeneaLogicJSON.decoder.decode(Artifact.self, from: emitted)
                #expect(decoded == artifact, "emit(parse(encode(v))) lost something — \(iteration)")
                #expect(
                    try JSONText.parse(emitted) == JSONText.parse(encoded),
                    "parse(emit(t)) != t — \(iteration)")
            } catch {
                Issue.record("\(error) — \(iteration)")
            }
        }
    }

    /// Every hostile string survives the emitter scalar for scalar — the same check
    /// 62's review added to the encoder, for the same reason (`==` is canonical
    /// equivalence and would hide a normalizing emitter).
    @Test func emitterKeepsEveryHostileString() throws {
        for hostile in Gen.hostileStrings {
            let node = JSONNode.object([.init(key: "k", value: .string(hostile))])
            guard case .object(let members) = try JSONText.parse(JSONText.emit(node)),
                case .string(let back) = members.first?.value
            else {
                Issue.record("emit/parse lost the object for \(hostile.debugDescription)")
                continue
            }
            #expect(back.unicodeScalars.elementsEqual(hostile.unicodeScalars))
        }
    }

    /// The exhaustive set really is exhaustive: one truncation per byte, a drop and a
    /// duplicate per member, a retype per site per value, and the unbounded families.
    @Test func exhaustiveCoversEveryFiniteFamily() throws {
        let bytes = Data(#"{"a":1,"b":[true,"s"],"c":{"d":null}}"#.utf8)
        let mutants = try JSONMutator.exhaustive(bytes)
        let labels = mutants.map(\.label)
        #expect(labels.filter { $0.hasPrefix("truncate") }.count == bytes.count)
        #expect(labels.filter { $0.hasPrefix("drop ") }.count == 4)  // a, b, c, c.d
        #expect(labels.filter { $0.hasPrefix("duplicate key ") }.count == 4)
        let sites = 6  // a, b, b[0], b[1], c, c.d
        #expect(
            labels.filter { $0.hasPrefix("retype ") }.count
                == sites * JSONMutator.retypeValues.count)
        #expect(labels.contains { $0.hasPrefix("nest ") })
        #expect(labels.contains { $0.contains("-byte string") })
        #expect(labels.contains { $0.contains("-element array") })
        #expect(
            labels.filter { $0.hasPrefix("invalid UTF-8") }.count == JSONMutator.invalidUTF8.count)
        #expect(labels.contains("drop c.d"))
        #expect(labels.contains("retype b[1] to null"))
    }

    /// Each unbounded family produces what its name says.
    @Test func unboundedFamiliesAreWhatTheySay() throws {
        let tree = try JSONText.parse(Data(#"{"a":"v"}"#.utf8))
        let site = tree.sites[0]
        let nested = JSONMutator.nestedArrays(tree, at: site, name: "a").bytes
        #expect(nested.count == 2 * JSONMutator.nestingDepth + #"{"a":}"#.utf8.count)
        let long = JSONMutator.absurdString(tree, at: site, name: "a").bytes
        #expect(long.count == JSONMutator.absurdStringLength + #"{"a":""}"#.utf8.count)
        let spliced = JSONMutator.spliced(tree, at: site, name: "a", ("0xFF", [0xFF])).bytes
        #expect(spliced.contains(0xFF))
        #expect(String(data: spliced, encoding: .utf8) == nil)
        let wide = JSONMutator.absurdArray(tree, at: site, name: "a").bytes
        guard case .object(let members) = try JSONText.parse(wide),
            case .array(let elements) = members[0].value
        else { throw ParseFailure() }
        #expect(elements.count == JSONMutator.absurdArrayLength)
    }

    private struct ParseFailure: Error {}
}
