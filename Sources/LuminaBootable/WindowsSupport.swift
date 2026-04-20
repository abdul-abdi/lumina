// Sources/LuminaBootable/WindowsSupport.swift
//
// Windows 11 ARM input-quirk handling for v0.7.0 M4.
//
// macOS sends some keys to virtualized Windows guests that the inbox driver
// either drops or maps to the wrong character (notably backslash and the Fn
// row). The fix is per-key remapping at the input layer, before the keystroke
// reaches the VZ keyboard configuration.
//
// v0.7.0 ships only the remap *table* and a no-op remapper. The actual key
// translation lives in the Desktop app's pointer-input layer (M6) which can
// intercept NSEvent keystrokes and substitute. The data lives here so the
// app doesn't have to invent it.

import Foundation

/// Static map of macOS-side scancodes that need remapping for Windows 11 ARM.
///
/// Entries:
///   0x2A → 0x2B   "backslash" (US layout) — macOS reports 0x2A, Windows wants 0x2B
///   0x67 → 0x3B   F1 — Fn row offsets diverge
///   0x68 → 0x3C   F2
///   0x69 → 0x3D   F3
///   ... up through F12.
///
/// Codes are in the USB HID Usage Tables (Keyboard/Keypad page 0x07).
public struct WindowsInputQuirks: Sendable, Equatable {
    public let table: [UInt8: UInt8]

    public init(table: [UInt8: UInt8] = WindowsInputQuirks.defaultTable) {
        self.table = table
    }

    public static let defaultTable: [UInt8: UInt8] = [
        // Backslash: macOS HID 0x2A, Windows HID 0x2B
        0x2A: 0x2B,
        // F1-F12 row alignment
        0x67: 0x3B,  // F1
        0x68: 0x3C,  // F2
        0x69: 0x3D,  // F3
        0x6A: 0x3E,  // F4
        0x6B: 0x3F,  // F5
        0x6C: 0x40,  // F6
        0x6D: 0x41,  // F7
        0x6E: 0x42,  // F8
        0x6F: 0x43,  // F9
        0x70: 0x44,  // F10
        0x71: 0x57,  // F11
        0x72: 0x58,  // F12
    ]

    /// Map a single scancode through the table; pass through unchanged if
    /// not in the table. v0.7.0 callers (M6 Desktop app input layer) call
    /// this per-keystroke when the focused VM's `osFamily == .windows`.
    public func remap(_ scancode: UInt8) -> UInt8 {
        table[scancode] ?? scancode
    }
}
