// Sources/LuminaDesktopKit/LuminaDesktopKit.swift
//
// SwiftUI primitives for the Lumina Desktop app.
//
// Milestone scope (v0.7.0 M6):
//   - VirtualMachineView — thin SwiftUI wrapper around VZVirtualMachineView
//   - ImageLibraryView / NewVMWizard / SnapshotBrowser
//   - Preferences (CPU/memory limits, disk location, image library root)
//
// The actual .app bundle lives at Apps/LuminaDesktop/ as an Xcode
// project — SPM can't emit signed .app bundles with VM entitlements +
// App Sandbox. Xcode consumes this library target; the library is the
// portable part.

import Foundation
import SwiftUI
import Virtualization

/// Marker type reserved for M6. Actual views land with M6.
public enum LuminaDesktopKitVersion {
    public static let placeholder = "0.7.0-m1-scaffold"
}
