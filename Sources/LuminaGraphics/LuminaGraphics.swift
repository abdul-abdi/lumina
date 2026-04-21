// Sources/LuminaGraphics/LuminaGraphics.swift
//
// Display + input device helpers for the desktop VM use case.
//
// This target is opt-in — it's only reachable when `VMOptions.graphics`
// is explicitly non-nil. The agent runtime path (`lumina run`,
// `lumina session start`) never sets that, so agents pay nothing for
// the existence of this target.
//
// See `GraphicsConfig+Factories.swift` for the public convenience builders.

import Foundation
import Lumina

/// Module marker + version string. Bump with each milestone that changes
/// the public surface.
public enum LuminaGraphics {
    public static let version = "0.7.0-m2"
}
