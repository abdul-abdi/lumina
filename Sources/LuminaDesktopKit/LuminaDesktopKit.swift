// Sources/LuminaDesktopKit/LuminaDesktopKit.swift
//
// SwiftUI primitives for the Lumina Desktop app.
//
// The actual `.app` bundle lives at `Apps/LuminaDesktop/` as an Xcode
// project — SPM can't emit a signed `.app` with VM entitlements + App
// Sandbox. Xcode consumes this library target; the library is the
// portable part.

import Foundation
import Lumina
import LuminaGraphics

/// Module marker + version string. Bump with each milestone that changes
/// the public surface.
public enum LuminaDesktopKit {
    public static let version = "0.7.0-m2"
}
