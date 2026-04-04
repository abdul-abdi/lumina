// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumina",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lumina", targets: ["Lumina"]),
        .executable(name: "lumina", targets: ["lumina-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "Lumina",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "lumina-cli",
            dependencies: [
                "Lumina",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LuminaTests",
            dependencies: [
                "Lumina",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
