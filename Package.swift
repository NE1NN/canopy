// swift-tools-version: 6.2
import PackageDescription

// What builds on Linux too: the wire format, what canopy-box shares with the Mac, and their tests.
let portableTargets: [Target] = [
    // What the Mac and the iPhone app both speak. It builds for iOS, so it has nothing platform-specific.
    .target(name: "CanopyWire"),
    // What the Mac app and canopy-box need from the operating system, on macOS and Linux alike.
    .target(name: "CanopySystem"),
    // Helpers every test target shares.
    .target(name: "CanopyTestSupport", dependencies: ["CanopySystem"]),
    .testTarget(name: "CanopyWireTests", dependencies: ["CanopyWire"]),
    .testTarget(name: "CanopySystemTests", dependencies: ["CanopySystem", "CanopyTestSupport"]),
]

let macTargets: [Target] = [
    .target(name: "CPty"),
    // The iPhone app's models and its connection to the Mac, kept out of its views so they test on the Mac.
    .target(name: "CanopyPhone", dependencies: ["CanopyWire"]),
    .target(name: "CanopyCore", dependencies: ["CPty", "CanopyWire", "CanopySystem"]),
    // Plugins are built in, each in a module of its own that only the app, the CLI, and tests import.
    .target(name: "CanopyFixturePlugin", dependencies: ["CanopyCore"]),
    .target(name: "CanopyTickets", dependencies: ["CanopyCore"]),
    .executableTarget(
        name: "CanopyApp",
        dependencies: [
            "CanopyCore", "CanopyFixturePlugin", "CanopyTickets",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]
    ),
    .executableTarget(
        name: "CanopyCLI",
        dependencies: [
            "CanopyCore", "CanopyTickets",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .testTarget(name: "CanopyPhoneTests", dependencies: ["CanopyPhone"]),
    .testTarget(
        name: "CanopyCoreTests", dependencies: ["CanopyCore", "CanopyFixturePlugin", "CanopyTestSupport"],
        resources: [.copy("Fixtures")]
    ),
    .testTarget(
        name: "CanopyCLITests",
        dependencies: [
            "CanopyCLI", "CanopyCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    .testTarget(
        name: "CanopyTicketsTests", dependencies: ["CanopyCore", "CanopyTickets"], resources: [.copy("Fixtures")]),
]

#if os(Linux)
    let package = Package(
        name: "Canopy",
        products: [.library(name: "CanopyWire", targets: ["CanopyWire"])],
        targets: portableTargets
    )
#else
    let package = Package(
        name: "Canopy",
        // iOS is for CanopyWire and CanopyPhone, which the iPhone app builds. Every other target needs macOS.
        platforms: [.macOS(.v15), .iOS(.v18)],
        products: [
            .executable(name: "CanopyApp", targets: ["CanopyApp"]),
            .executable(name: "canopy", targets: ["CanopyCLI"]),
            .library(name: "CanopyWire", targets: ["CanopyWire"]),
            .library(name: "CanopyPhone", targets: ["CanopyPhone"]),
        ],
        dependencies: [
            .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
            .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        ],
        targets: portableTargets + macTargets
    )
#endif
