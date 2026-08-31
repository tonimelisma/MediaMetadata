// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MediaMetadata",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "MediaMetadata",
            targets: ["MediaMetadata"]
        ),
    ],
    targets: [
        // Swift 6 language mode. The package is value types and synchronous parsing, so
        // strict concurrency costs nothing here — but it is what makes the execution
        // contract compiler-checked for consumers rather than a convention in the README.
        .target(name: "MediaMetadata"),
        .testTarget(
            name: "MediaMetadataTests",
            dependencies: ["MediaMetadata"]
        ),
    ]
)
