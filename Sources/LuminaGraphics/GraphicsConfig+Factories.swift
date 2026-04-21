// Sources/LuminaGraphics/GraphicsConfig+Factories.swift
//
// Convenience factories for `GraphicsConfig`. The config type itself lives
// in Lumina core so VM.swift can read it without depending on this target;
// the builders live here so agent-runtime users never see desktop
// boilerplate cluttering the public surface.

import Foundation
import Lumina

public extension GraphicsConfig {
    /// Sensible Full HD default for Linux / Windows-on-ARM guests:
    /// 1920×1080, USB keyboard, USB screen-coordinate mouse.
    static let defaultDesktop = GraphicsConfig(
        widthInPixels: 1920,
        heightInPixels: 1080,
        keyboardKind: .usb,
        pointingDeviceKind: .usbScreenCoordinate
    )

    /// Compact 1280×720 config — useful for low-memory runs or CI smoke tests.
    static let compact = GraphicsConfig(
        widthInPixels: 1280,
        heightInPixels: 720,
        keyboardKind: .usb,
        pointingDeviceKind: .usbScreenCoordinate
    )

    /// 4K display. Pairs with `.cpus 4` and `memory 4GB+` in practice.
    static let fourK = GraphicsConfig(
        widthInPixels: 3840,
        heightInPixels: 2160,
        keyboardKind: .usb,
        pointingDeviceKind: .usbScreenCoordinate
    )

    /// Retina-style config at an arbitrary resolution. Useful when you
    /// want to match a physical display pixel-exactly.
    static func resolution(width: Int, height: Int) -> GraphicsConfig {
        GraphicsConfig(
            widthInPixels: width,
            heightInPixels: height,
            keyboardKind: .usb,
            pointingDeviceKind: .usbScreenCoordinate
        )
    }

    /// macOS-guest-optimised config — uses Mac keyboard + trackpad devices.
    /// Intended to pair with the macOS guest VM type landing in v0.7.0 M5.
    static let macGuest = GraphicsConfig(
        widthInPixels: 2560,
        heightInPixels: 1440,
        keyboardKind: .mac,
        pointingDeviceKind: .trackpad
    )
}
