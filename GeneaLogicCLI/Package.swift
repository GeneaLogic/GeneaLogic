// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GeneaLogicCLI",
    platforms: [.macOS(.v26)],
    products: [
        .executable(
            name: "genea",
            targets: ["GeneaLogicCLI"]
        )
    ],
    dependencies: [
        // The engine package, by relative path — sibling top-level component
        // (CLAUDE.md "Project shape"). The engine has no CLI/UI dependency in
        // the other direction.
        .package(path: "../GeneaLogicKit"),
        // Apple's argument-parsing library. Lives ONLY in this package — never
        // added to GeneaLogicKit, which keeps a lean, Foundation-only dependency
        // set for the Linux/Vapor build (CLAUDE.md).
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "GeneaLogicCLI",
            dependencies: [
                .product(name: "GeneaLogicArchive", package: "GeneaLogicKit"),
                .product(name: "GeneaLogicModel", package: "GeneaLogicKit"),
                .product(name: "GeneaLogicSample", package: "GeneaLogicKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GeneaLogicCLI"
        ),
        .testTarget(
            name: "GeneaLogicCLITests",
            dependencies: [
                "GeneaLogicCLI",
                .product(name: "GeneaLogicArchive", package: "GeneaLogicKit"),
                .product(name: "GeneaLogicModel", package: "GeneaLogicKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tests/GeneaLogicCLITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
