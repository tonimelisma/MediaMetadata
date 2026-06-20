// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MediaMetadata",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MediaMetadata",
            targets: ["MediaMetadata"]
        ),
    ],
    targets: [
        .target(name: "MediaMetadata"),
        .testTarget(
            name: "MediaMetadataTests",
            dependencies: ["MediaMetadata"]
        ),
    ]
)
