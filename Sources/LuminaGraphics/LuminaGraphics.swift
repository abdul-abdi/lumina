// Sources/LuminaGraphics/LuminaGraphics.swift
//
// Display + input device helpers for the desktop VM use case.
//
// This target is opt-in — it's only reachable when `VMOptions.graphics`
// is explicitly non-nil. The agent runtime path (`lumina run`,
// `lumina session start`) never sets that, so agents pay nothing for
// the existence of this target.
//
// Milestone scope (v0.7.0 M2):
//   - VZGraphicsDevice wiring via `GraphicsConfig`
//   - VZVirtioKeyboard attachment
//   - VZUSBScreenCoordinatePointingDevice attachment
//   - SwiftUI-friendly helpers that return a VZVirtualMachineView-ready
//     VZVirtualMachine, without leaking VZ types across actor boundaries

import Foundation
import Virtualization

/// Marker type reserved for M2. Presence of the module makes `import LuminaGraphics`
/// resolve; actual public API lands with M2.
public enum LuminaGraphicsVersion {
    public static let placeholder = "0.7.0-m1-scaffold"
}
