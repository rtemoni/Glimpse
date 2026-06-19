// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Glimpse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GlimpseCore",
            targets: ["GlimpseCore"]
        ),
        .executable(
            name: "Glimpse",
            targets: ["Glimpse"]
        )
    ],
    targets: [
        .target(
            name: "GlimpseCore"
        ),
        .executableTarget(
            name: "Glimpse",
            dependencies: ["GlimpseCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "GlimpseCoreTests",
            dependencies: ["GlimpseCore"]
        )
    ]
)
