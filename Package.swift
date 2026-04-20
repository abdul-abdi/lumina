// swift-tools-version: 6.0
import PackageDescription

// Lumina is a multi-product package.
//
//   Lumina            — headless agent runtime. Zero external deps beyond
//                       Virtualization.framework. Agent path boot time is
//                       sacred; every other target must stay out of this
//                       critical section.
//
//   LuminaGraphics    — optional display + input device helpers for the
//                       desktop use case. Layered on top of Lumina; never
//                       imported by the headless path.
//
//   LuminaBootable    — ISO / IPSW / EFI boot pipelines for full-OS
//                       guests (Linux desktop, Windows 11 ARM, macOS).
//
//   LuminaDesktopKit  — SwiftUI primitives (VZVirtualMachineView wrapper,
//                       image-library views). Depends on LuminaGraphics +
//                       LuminaBootable. The actual .app bundle lives in
//                       Apps/LuminaDesktop/ as an Xcode project — SPM
//                       can't emit a signed .app with entitlements.
//
// Agent protection invariant: nothing in LuminaGraphics / LuminaBootable /
// LuminaDesktopKit is reachable from `lumina run` or `lumina session start`
// unless `VMOptions.graphics` is explicitly non-nil.

let package = Package(
    name: "Lumina",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lumina", targets: ["Lumina"]),
        .library(name: "LuminaGraphics", targets: ["LuminaGraphics"]),
        .library(name: "LuminaBootable", targets: ["LuminaBootable"]),
        .library(name: "LuminaDesktopKit", targets: ["LuminaDesktopKit"]),
        .executable(name: "lumina", targets: ["lumina-cli"]),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: - v0.7.0 desktop stack (opt-in; agent path untouched)

        .target(
            name: "LuminaGraphics",
            dependencies: ["Lumina"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .target(
            name: "LuminaBootable",
            dependencies: ["Lumina"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .target(
            name: "LuminaDesktopKit",
            dependencies: ["Lumina", "LuminaGraphics", "LuminaBootable"],
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
            name: "LuminaGraphicsTests",
            dependencies: [
                "LuminaGraphics",
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
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
