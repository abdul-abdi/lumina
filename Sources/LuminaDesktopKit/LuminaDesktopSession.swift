// Sources/LuminaDesktopKit/LuminaDesktopSession.swift
//
// v0.7.0 M6 — the MainActor bridge from `Lumina.VM` (an actor) to
// SwiftUI views (which observe `@Observable @MainActor` state).
//
// The bridge owns a `Lumina.VM` and a snapshot of its observable state
// (status, last error, serial output digest). SwiftUI views read these
// `@Observable` properties; the actor mirrors changes into them via
// `Task { @MainActor in ... }` after each mutation.
//
// Why not pass the actor directly into views: SwiftUI re-evaluates view
// bodies on every state change. Calling `await session.vm.state` from
// inside a body would suspend rendering and force every observer to
// await — broken UX. Instead we cache the actor's state in main-actor
// properties and mirror updates explicitly.

import Foundation
import Observation
import SwiftUI
@preconcurrency import Virtualization
import Lumina
import LuminaBootable

@MainActor
@Observable
public final class LuminaDesktopSession: Identifiable {
    public nonisolated let id: UUID
    public nonisolated let bundle: VMBundle

    public enum Status: Sendable, Equatable {
        case stopped
        case booting
        case running
        case paused
        case crashed(reason: String)
        case shuttingDown

        public var isLive: Bool {
            switch self {
            case .booting, .running, .paused: return true
            default: return false
            }
        }

        public var label: String {
            switch self {
            case .stopped: "Stopped"
            case .booting: "Booting…"
            case .running: "Running"
            case .paused: "Paused"
            case .crashed(let r): "Crashed: \(r)"
            case .shuttingDown: "Shutting down…"
            }
        }
    }

    public var status: Status = .stopped
    public var lastError: String?
    public var bootDuration: Duration?
    public var serialDigest: String = ""

    /// The underlying VM actor. Held nonisolated; access from main actor
    /// goes through the helper methods below which await it.
    private nonisolated(unsafe) var vm: VM?

    public init(bundle: VMBundle) {
        self.id = bundle.manifest.id
        self.bundle = bundle
    }

    public func boot() async {
        status = .booting
        lastError = nil
        let start = ContinuousClock.now

        var opts = VMOptions.default
        opts.memory = bundle.manifest.memoryBytes
        opts.cpuCount = bundle.manifest.cpuCount
        opts.bootable = .efi(EFIBootConfig(
            variableStoreURL: bundle.efiVarsURL,
            primaryDisk: bundle.primaryDiskURL,
            cdromISO: pendingCDROM()
        ))
        opts.graphics = GraphicsConfig(
            widthInPixels: 1920,
            heightInPixels: 1080,
            keyboardKind: bundle.manifest.osFamily == .windows ? .usb : .usb,
            pointingDeviceKind: .usbScreenCoordinate
        )
        opts.sound = SoundConfig(enabled: true)

        let newVM = VM(options: opts)
        self.vm = newVM
        do {
            try await newVM.boot()
            self.status = .running
            self.bootDuration = ContinuousClock.now - start
        } catch {
            self.status = .crashed(reason: "\(error)")
            self.lastError = "\(error)"
        }
    }

    public func shutdown() async {
        status = .shuttingDown
        if let vm = self.vm {
            await vm.shutdown()
        }
        self.vm = nil
        status = .stopped
    }

    /// Returns the underlying `VZVirtualMachine` for `LuminaVirtualMachineView`
    /// to render. Nil when no VM is booted.
    public func virtualMachine() async -> VZVirtualMachine? {
        guard let vm = self.vm else { return nil }
        let handle = await vm.vzMachine()
        return handle.machine
    }

    /// Read the current pending-iso sidecar (set by `lumina desktop create
    /// --iso`). Cleared after first boot.
    private func pendingCDROM() -> URL? {
        let sidecar = bundle.rootURL.appendingPathComponent("pending-iso.path")
        guard let data = try? Data(contentsOf: sidecar),
              let path = String(data: data, encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
