/// A seeded, platform-independent pseudo-random generator for property tests
/// (slice 62, fork a).
///
/// `SystemRandomNumberGenerator` cannot be seeded, so a failing property could never
/// be re-run. This is SplitMix64 (Steele, Lea & Flood 2014): a 64-bit state, one
/// addition and two xor-shift-multiplies per output, and — the property that matters
/// here — **the same sequence for the same seed on every platform**, because it uses
/// nothing but wrapping integer arithmetic. `PropertyDeterminismTests` pins the first
/// outputs of a fixed seed so a Linux failure is reproducible on a Mac.
///
/// Every generator in this module draws from one of these and nothing else, so a
/// generated value is a pure function of `(seed, draw order)`.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
