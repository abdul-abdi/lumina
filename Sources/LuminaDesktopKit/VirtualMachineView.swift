// Sources/LuminaDesktopKit/VirtualMachineView.swift
//
// SwiftUI bridge to `VZVirtualMachineView`.
//
// Keeps the VZ types inside the file so the rest of LuminaDesktopKit can
// import SwiftUI and Lumina without dragging `Virtualization` into every
// source file.
//
// Milestone scope (M2): the SwiftUI bridge is ready; the `VirtualMachine`
// parameter plumbing lands with M3 when we actually boot a desktop guest
// and need to render its framebuffer. Until then this view renders a
// placeholder and is used only to prove the import graph.

import SwiftUI
import Virtualization

/// SwiftUI wrapper around `VZVirtualMachineView`.
///
/// `virtualMachine` is optional to allow wiring up the view before a VM
/// exists (e.g. while boot is in flight); when nil the view renders an
/// empty state.
///
/// This type is `@MainActor`-bound because AppKit views must be touched
/// on the main actor.
@MainActor
public struct LuminaVirtualMachineView: NSViewRepresentable {
    public var virtualMachine: VZVirtualMachine?
    public var capturesSystemKeys: Bool

    public init(virtualMachine: VZVirtualMachine? = nil, capturesSystemKeys: Bool = false) {
        self.virtualMachine = virtualMachine
        self.capturesSystemKeys = capturesSystemKeys
    }

    public func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = capturesSystemKeys
        return view
    }

    public func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = virtualMachine
        nsView.capturesSystemKeys = capturesSystemKeys
    }
}
