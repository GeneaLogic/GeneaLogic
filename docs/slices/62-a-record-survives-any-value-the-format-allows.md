# 62 — a record survives any value the format allows ✅

**Problem.** Round-trip coverage is example-based: ~1,500 lines of hand-written values in
`RoundTripTests` and seven golden fixtures. That proves the shapes someone thought of. The
spec makes promises over *spaces* — §7's "an unrecognized open-vocabulary value round-trips
verbatim", §3's "absent and `null` mean the same thing", EDTF strings stored untouched, names
compared under NFC — and no test walks a space. The property version is `decode(encode(v)) ==
v` and byte-stable re-encode over generated values of every persisted type, which is also the
substrate 66 needs.

**Layer.** Tests only, plus one package-structure addition. **No format change.** No
production change is *expected*; anything the property finds is a defect and is fixed in the
slice (55's rule for defects a slice reveals), with the minimized input checked in as a golden
fixture.

**Design forks** (settled 2026-09-13):

- **(a) Hand-rolled, not a library.** A seeded PRNG (SplitMix64 — `SystemRandomNumberGenerator`
  is not seedable) and per-type generators in a new **`GeneaLogicTestSupport`** target:
  a library target, not a product, depending on Foundation and `GeneaLogicModel` only, so
  `GeneaLogicModelTests` (this slice) and `GeneaLogicArchiveTests` (66) both import it. The
  alternative — duplicating or symlinking generator files between test targets — was rejected
  as the thing that drifts. No new package dependency.
- **(b) Budget.** `GENEALOGIC_PROPERTY_ITERATIONS` (default **200** per property) and
  `GENEALOGIC_PROPERTY_SEED`; every failure message prints the seed and iteration, so a CI
  failure reproduces locally with one environment variable. CI runs the default; a longer
  soak is a local decision. **No corpus directory** — a found failure is minimized by hand and
  becomes a fixture under the existing `Fixtures/` mechanism.
- **(c) What is generated.** Every persisted `Codable` type, through its public initializer:
  the `Artifact` tree (`PersonMention`, `RecordedFact`, `FileEntry`, `Event`, `Location`,
  `Retrieval`, `EmbeddedMetadata`, `ExternalIdentifier`, `MentionRelationship`), `Person`
  (`PersonName`, `PersonFact`), `Relationship`, `EvidenceLink` (`MatchBreakdown`,
  `MatchDimension`), `Dismissal`, `Manifest`/`ManifestEntry`, `TrashEntry`. Open vocabularies
  generate `.unknown` cases at a fixed rate; closed ones draw from `CaseIterable`. Optionals
  are absent and present. Strings draw from a hostile-but-legal set — empty, NFC/NFD pairs,
  RTL, combining marks, emoji, every JSON-escapable character, long — as well as plain text.
  Floats are finite only; the encoder's `.throw` on non-finite is a separate, direct test.
  `GeneaLogicMatch` types are not persisted and are out.
- **(d) The properties.** For each type: **(1)** `decode(encode(v)) == v`; **(2)**
  `encode(decode(encode(v))) == encode(v)`, byte-for-byte — the property 49's checksums and
  58's index blobs both rest on; **(3)** `prettyEncoder` decodes to the same value; **(4)**
  §3's rule — replacing any absent optional key with an explicit `null` decodes to the same
  value as omitting it. The existing example tests stay; they are the readable half.
- **(e) Determinism across platforms is itself a property.** The same seed must produce the
  same values on macOS and Linux, or a Linux failure cannot be reproduced on a Mac. One test
  pins the first few values for a fixed seed.

**Out of scope:** mutated or truncated bytes (**63**); version handling (**64**); anything
at the archive level (**66**); generators for types that are never written to disk.

**How it will be verified.** `swift test` on both platforms — Linux is the one that matters
here, for (e). `SchemaSpecTests` untouched. **No hand-test**: nothing is user-visible, and
saying so is the honest handoff.

**Shipped as specced**, with two corrections to fork (c) the code found: `EmbeddedMetadata` is
not persisted (it is extracted at attach and surfaced on `AttachedFile`, never written), so it
gets no generator — the spec's own rule for types nothing writes; and no persisted type has a
floating-point field, so the encoder's non-finite `.throw` is tested directly against a probe
struct rather than as a property. **The format passed**: 200 iterations per type in CI and a
5,000-iteration soak found nothing. 896 engine tests on macOS, 893 on Linux, the pinned
generator values identical on both.
