// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GeneaLogicKit",
    // Matched to the app's own deployment target (macOS 26.5). The previous floor —
    // macOS 13 — was a manifest line nothing documented, nothing exercised (no
    // `@available` in the package), and which its own comment justified as swift-crypto's
    // macOS 10.15 minimum. Since the only Apple consumer is the 26.5 app, the low floor
    // bought nothing and cost the modern concurrency primitives (`Synchronization`'s
    // `Mutex` needs macOS 15).
    // `platforms` constrains ONLY Apple OSes — Linux ignores it, so the Linux/Vapor
    // build is unaffected by these declarations.
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(
            name: "GeneaLogicModel",
            targets: ["GeneaLogicModel"]
        ),
        .library(
            name: "GeneaLogicArchive",
            targets: ["GeneaLogicArchive"]
        ),
        // The concrete embedded-metadata extractor (ARCHITECTURE.md §6.4). Apple
        // build wraps ImageIO; the core does NOT depend on it (consumers inject
        // it into `attachFile`). Its sources are `#if canImport(ImageIO)`-guarded
        // so the target compiles to an empty module on Linux — keeping the Linux
        // build green and leaving the door open for a future libexif/pure-Swift
        // Linux conformer (Phase 6 stretch).
        .library(
            name: "GeneaLogicExtract",
            targets: ["GeneaLogicExtract"]
        ),
        // Entity-resolution & confidence scoring (ARCHITECTURE.md §4.6, §6.2).
        // Pure functions over model value types — no archive, no I/O, no UI.
        .library(
            name: "GeneaLogicMatch",
            targets: ["GeneaLogicMatch"]
        ),
        // The sample archive (slice 74b): one invented family, built through the public
        // API, for the app's welcome screen and `genea sample`.
        .library(
            name: "GeneaLogicSample",
            targets: ["GeneaLogicSample"]
        ),
    ],
    dependencies: [
        // SHA-256 for the archive's integrity manifest. swift-crypto is the
        // mandated checksum library (CLAUDE.md): it builds on Linux, unlike
        // Apple-only CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "GeneaLogicModel",
            path: "Sources/GeneaLogicModel"
        ),
        // The vendored SQLite amalgamation (see Sources/CSQLite/README.md for
        // the pinned version, source URL, and update procedure). Flags mirror
        // the Phase 1b spike (docs/spikes/sqlite-driver.md): FTS5 for future full-text
        // search, threadsafe mode as defense-in-depth alongside Archive's own
        // NSLock, and DQS=0 to disable the double-quoted-string-as-identifier
        // fallback.
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_DQS", to: "0"),
            ]
        ),
        .target(
            name: "GeneaLogicArchive",
            dependencies: [
                "GeneaLogicModel",
                "CSQLite",
                // The matcher's scoring core (slice 45), projected onto real records
                // by `Archive+Matching.swift` (slice 45b). The dependency runs this
                // way and only this way: the archive knows how to build the scorer's
                // value views, and the scorer stays ignorant of archives, filesystems
                // and SQLite — which is what lets the Phase 4 Vapor target reuse it.
                "GeneaLogicMatch",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/GeneaLogicArchive",
            resources: [
                .copy("Resources/genealogic-archive-1.0.md")
            ]
        ),
        // Concrete `MetadataExtractor` conformer(s). Depends only on the model
        // (the protocol + `EmbeddedMetadata`), never on the core. ImageIO sources
        // are `#if canImport(ImageIO)`-guarded so this builds (empty) on Linux.
        .target(
            name: "GeneaLogicExtract",
            dependencies: ["GeneaLogicModel"],
            path: "Sources/GeneaLogicExtract"
        ),
        // The matcher's scoring core (slice 45). Depends on the model only — it takes
        // plain value views of a person and a mention, never an `Archive`, so it is
        // testable without a filesystem and reusable by the Phase 4 Vapor target.
        // Projecting an archive into those views is slice 45b's job, deliberately
        // on the other side of this seam.
        .target(
            name: "GeneaLogicMatch",
            dependencies: ["GeneaLogicModel"],
            path: "Sources/GeneaLogicMatch"
        ),
        // Builds the sample archive. Its page images are committed resources, rendered by
        // `scripts/render-sample-pages.swift`; the target only copies their bytes, so it
        // stays Foundation-only and builds on Linux.
        .target(
            name: "GeneaLogicSample",
            dependencies: ["GeneaLogicArchive", "GeneaLogicModel"],
            path: "Sources/GeneaLogicSample",
            resources: [
                .copy("Resources/pages")
            ]
        ),
        // Seeded generators for the property tests (slice 62): a library target, not a
        // product, so the model tests (round-trips) and the archive tests (66's
        // rebuild-equivalence) draw the same values from the same code. Foundation and
        // the model only — it has to build on Linux with everything else.
        .target(
            name: "GeneaLogicTestSupport",
            dependencies: ["GeneaLogicModel"],
            path: "Sources/GeneaLogicTestSupport"
        ),
        .testTarget(
            name: "GeneaLogicModelTests",
            dependencies: ["GeneaLogicModel", "GeneaLogicTestSupport"],
            path: "Tests/GeneaLogicModelTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "GeneaLogicArchiveTests",
            dependencies: ["GeneaLogicArchive", "GeneaLogicModel", "GeneaLogicTestSupport"],
            path: "Tests/GeneaLogicArchiveTests"
        ),
        .testTarget(
            name: "GeneaLogicExtractTests",
            dependencies: ["GeneaLogicExtract", "GeneaLogicModel"],
            path: "Tests/GeneaLogicExtractTests"
        ),
        .testTarget(
            name: "GeneaLogicSampleTests",
            dependencies: ["GeneaLogicSample", "GeneaLogicArchive", "GeneaLogicModel"],
            path: "Tests/GeneaLogicSampleTests"
        ),
        .testTarget(
            name: "GeneaLogicMatchTests",
            dependencies: ["GeneaLogicMatch", "GeneaLogicModel"],
            path: "Tests/GeneaLogicMatchTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
