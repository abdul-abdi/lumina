// swift-tools-version: 6.0
import PackageDescription

// Lumina is a multi-product package.
//
//   Lumina            — core runtime. Zero external deps beyond
//                       Virtualization.framework. Hosts both the headless
//                       agent path (`VM` actor, `CommandRunner`) and the
//                       full-OS bootable code (`EFIBootable`, `MacOSVM`,
//                       `MacOSSupport`, `ClipboardProtocol`) because
//                       `VM.boot()` dispatches across all three profiles;
//                       placing the bootable code in `LuminaBootable`
//                       would cycle. Dead-code elimination keeps it out
//                       of the agent path's runtime footprint, and the
//                       `effectiveBootable` switch at the top of
//                       `VM.boot()` routes `.efi` / `.macOS` away from
//                       the agent hot path byte-for-byte.
//
//   LuminaGraphics    — optional display + input device helpers for the
//                       desktop use case. Layered on top of Lumina; never
//                       imported by the headless path.
//
//   LuminaBootable    — higher-level ISO / IPSW boot surfaces that don't
//                       need to live next to `VM`: `VMBundle`,
//                       `DesktopOSCatalog`, `IPSWCatalog`,
//                       `DiskImageAllocator`, `ISOInspector`,
//                       `CloudInitSeed`, `WindowsSupport`.
//
//   LuminaDesktopKit  — SwiftUI primitives (VZVirtualMachineView wrapper,
//                       image-library views). Depends on LuminaGraphics +
//                       LuminaBootable. The actual .app bundle lives in
//                       Apps/LuminaDesktop/ as an Xcode project — SPM
//                       can't emit a signed .app with entitlements.
//
// Agent protection invariant: the agent path through `VM.boot()` (the
// `.agent` case of `BootableProfile`) is byte-identical to v0.6.0, and
// nothing in LuminaGraphics / LuminaBootable / LuminaDesktopKit is
// reachable from `lumina run` or `lumina session start` unless the
// caller opts in via `VMOptions.graphics` or `VMOptions.bootable`.

let package = Package(
    name: "Lumina",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lumina", targets: ["Lumina"]),
        .library(name: "LuminaGraphics", targets: ["LuminaGraphics"]),
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
                "LuminaGraphics",
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
                "LuminaBootable",  // M6 tests use VMBundle directly
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
