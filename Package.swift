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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .target(
            name: "GlimpseCore"
        ),
        .executableTarget(
            name: "Glimpse",
            dependencies: [
                "GlimpseCore",
                .product(
                    name: "Sparkle",
                    package: "Sparkle",
                    condition: .when(platforms: [.macOS])
                )
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(platforms: [.macOS])
                )
            ]
        ),
        .testTarget(
            name: "GlimpseCoreTests",
            dependencies: ["GlimpseCore"]
        )
    ]
)
