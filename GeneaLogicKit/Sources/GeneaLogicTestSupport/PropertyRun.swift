import Foundation

/// One run of a property: how many iterations, from which seed, and — the part that
/// makes a failure worth anything — how to say which iteration failed so it can be
/// re-run alone (slice 62, fork b).
///
/// Configured from the environment so CI and a local soak use the same code:
///
/// - `GENEALOGIC_PROPERTY_ITERATIONS` — iterations per property (default 200).
/// - `GENEALOGIC_PROPERTY_SEED` — the seed for the run (default: a fixed one, so an
///   unconfigured run is reproducible by construction rather than fresh every time).
///
/// Every iteration derives its own generator from `(seed, index)`, so a single failing
/// iteration reproduces on its own without replaying the ones before it: set the seed
/// and iterations from the failure message and the same value is regenerated.
public struct PropertyRun: Sendable {
    public let seed: UInt64
    public let iterations: Int

    public static let defaultSeed: UInt64 = 0x6265_6E65_614C_6F67  // "GeneaLog", as bytes
    public static let defaultIterations = 200

    public init(seed: UInt64, iterations: Int) {
        self.seed = seed
        self.iterations = iterations
    }

    /// The run the environment asks for, or the defaults.
    ///
    /// A variable that is *set but unparsable* stops the run rather than falling back:
    /// a reproduction that silently ran the defaults would declare a real failure
    /// non-reproducible, which is worse than no reproduction at all.
    public static var fromEnvironment: PropertyRun {
        fromEnvironment(defaultIterations: defaultIterations)
    }

    /// The run the environment asks for, with a suite's own default budget — for a
    /// property whose iteration is an archive rather than a value (slice 66, fork e).
    /// The environment still wins, so a reproduction line works the same everywhere.
    public static func fromEnvironment(defaultIterations: Int) -> PropertyRun {
        let env = ProcessInfo.processInfo.environment
        let seed = parse(env["GENEALOGIC_PROPERTY_SEED"], as: UInt64.init) ?? defaultSeed
        let iterations =
            parse(env["GENEALOGIC_PROPERTY_ITERATIONS"], as: Int.init) ?? defaultIterations
        return PropertyRun(seed: seed, iterations: max(1, iterations))
    }

    private static func parse<T>(_ raw: String?, as convert: (String) -> T?) -> T? {
        guard let raw else { return nil }
        guard let value = convert(raw) else {
            preconditionFailure(
                "GENEALOGIC_PROPERTY_* variable set to \(raw.debugDescription), "
                    + "which is not a decimal \(T.self); refusing to run the defaults instead")
        }
        return value
    }

    /// One iteration of a run: its generator, and the words that reproduce it.
    public struct Iteration: CustomStringConvertible, Sendable {
        public let seed: UInt64
        public let index: Int

        public init(seed: UInt64, index: Int) {
            self.seed = seed
            self.index = index
        }

        /// A fresh generator positioned for this iteration. Mixing the index into the
        /// seed through one SplitMix step keeps neighbouring iterations uncorrelated.
        public var generator: SeededGenerator {
            var mixer = SeededGenerator(seed: seed ^ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            return SeededGenerator(seed: mixer.next())
        }

        /// What to put in the failure message: the environment that reproduces this
        /// iteration. Iterations before it re-run too, but each derives from its own
        /// `(seed, index)`, so this one regenerates the same value regardless.
        public var description: String {
            "GENEALOGIC_PROPERTY_SEED=\(seed) GENEALOGIC_PROPERTY_ITERATIONS=\(index + 1) "
                + "(iteration \(index))"
        }
    }

    /// Calls `body` once per iteration with that iteration's generator.
    public func forEach(_ body: (inout SeededGenerator, Iteration) throws -> Void) rethrows {
        for index in 0..<iterations {
            let iteration = Iteration(seed: seed, index: index)
            var generator = iteration.generator
            try body(&generator, iteration)
        }
    }
}
