// Sources/LuminaDesktopKit/MaterialBackground.swift
//
// v0.7.0 M6 — NSVisualEffectView wrapper for proper Mac-native translucency.
// SwiftUI's `.background(.ultraThinMaterial)` is fine for sheets but doesn't
// behave correctly as a window background — falls back to opaque on hidden
// title bars. We use the AppKit primitive directly.

import SwiftUI
import AppKit

public struct MaterialBackground: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blending: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blending = blending
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

/// Window controller config for hiding the title bar + unified toolbar.
public struct WindowAccessor: NSViewRepresentable {
    public let configure: (NSWindow) -> Void

    public init(configure: @escaping (NSWindow) -> Void) {
        self.configure = configure
    }

    public func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                self.configure(w)
            }
        }
        return v
    }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

public extension View {
    /// Configure the window this view is hosted in. Hides the title text,
    /// makes the toolbar transparent so our material background shows.
    func luminaWindowChrome() -> some View {
        self.background(WindowAccessor { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = false
        })
    }
}
