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
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "CPty"),
        .target(name: "CanopyCore", dependencies: ["CPty"]),
        .executableTarget(name: "CanopyApp", dependencies: ["CanopyCore"]),
        .executableTarget(
            name: "CanopyCLI",
            dependencies: [
                "CanopyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "CanopyCoreTests", dependencies: ["CanopyCore"]),
    ]
)
