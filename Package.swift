// swift-tools-version: 6.0
import PackageDescription

// Agent protection invariant: the agent path through `VM.boot()` is
// functionally equivalent to
// v0.6.0 within the CI agent-boot P50 budget — the new v0.7.0 additions
// (`efi` check, optional `graphics`/`sound` attachments)
// are guarded single-branch no-ops when `VMOptions.efi` and
// `VMOptions.graphics` are nil and `VMOptions.sound` is false. Nothing in
// LuminaBootable / LuminaDesktopKit is reachable from
// `lumina run` or `lumina session start` unless the caller opts in.
// The agent-boot P50 gate in .github/workflows/ci.yml enforces the
// timing contract.

let package = Package(
    name: "Lumina",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lumina", targets: ["Lumina"]),
        .library(name: "LuminaBootable", targets: ["LuminaBootable"]),
        .library(name: "LuminaDesktopKit", targets: ["LuminaDesktopKit"]),
        .executable(name: "lumina", targets: ["lumina-cli"]),
        .executable(name: "LuminaDesktopApp", targets: ["LuminaDesktopApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        // MARK: - Headless agent runtime (unchanged contract)

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
                "LuminaBootable",  // v0.7.0 M3+: lumina desktop subcommand tree
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // v0.7.0 M6: SwiftUI app entry point. Built with SPM so it runs
        // without Xcode. The Apps/LuminaDesktop/ Xcode project exists for
        // contributors who want to use Xcode, but is not required.
        // The build script wraps the executable in an .app bundle.
        .executableTarget(
            name: "LuminaDesktopApp",
            dependencies: [
                "Lumina",
                "LuminaBootable",
                "LuminaDesktopKit",
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Virtualization"),
            ]
        ),

        // MARK: - v0.7.0 desktop stack (opt-in; agent path untouched)

        .target(
            name: "LuminaBootable",
            dependencies: ["Lumina"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .target(
            name: "LuminaDesktopKit",
            dependencies: ["Lumina", "LuminaBootable"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("Virtualization"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "LuminaTests",
            dependencies: [
                "Lumina",
                "LuminaBootable",  // M3+: shared helpers (DiskImageAllocator) in cross-target tests
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "LuminaBootableTests",
            dependencies: [
                "LuminaBootable",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "LuminaDesktopKitTests",
            dependencies: [
                "LuminaDesktopKit",
                "LuminaBootable",  // M6 tests use VMBundle directly
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
