// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CanopyApp", targets: ["CanopyApp"]),
        .executable(name: "canopy", targets: ["CanopyCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .target(name: "CPty"),
        .target(name: "CanopyCore", dependencies: ["CPty"]),
        // Plugins are built in, each in a module of its own that only the app, the CLI, and tests import.
        .target(name: "CanopyFixturePlugin", dependencies: ["CanopyCore"]),
        .executableTarget(
            name: "CanopyApp",
            dependencies: [
                "CanopyCore", "CanopyFixturePlugin", .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "CanopyCLI",
            dependencies: [
                "CanopyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "CanopyCoreTests", dependencies: ["CanopyCore", "CanopyFixturePlugin"]),
    ]
)
