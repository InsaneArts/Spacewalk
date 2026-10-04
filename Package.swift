// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spacewalk",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpacewalkCore", targets: ["SpacewalkCore"]),
        .executable(name: "Spacewalk", targets: ["Spacewalk"]),
        .executable(name: "spacewalk-cli", targets: ["SpacewalkCLI"]),
    ],
    dependencies: [
        // The one third-party dependency: self-updates, signed with EdDSA, from appcast.xml in this repo.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "SpacewalkCore",
            path: "Sources/SpacewalkCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Spacewalk",
            dependencies: ["SpacewalkCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Spacewalk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SpacewalkCLI",
            dependencies: ["SpacewalkCore"],
            path: "Sources/SpacewalkCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpacewalkCoreTests",
            dependencies: ["SpacewalkCore"],
            path: "Tests/SpacewalkCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
