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

    /// Forwarder keeping `VZVirtualMachineDelegate` callbacks alive.
    /// VZ holds the delegate weakly, so we retain it here until the
    /// session is torn down.
    private var vmDelegate: VMStopForwarder?

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
            // Attach stop observer so guest-initiated `poweroff`, external
            // crashes, and any other VZ-side termination flip status back
            // to .stopped / .crashed. Without this the menu bar (and the
            // rest of the UI) keeps a dead VM in the RUNNING list.
            await attachStopObserver(to: newVM)
        } catch {
            self.status = .crashed(reason: "\(error)")
            self.lastError = "\(error)"
        }
    }

    private func attachStopObserver(to vm: VM) async {
        let forwarder = VMStopForwarder(
            onGuestStop: { [weak self] in
                Task { @MainActor in self?.handleExternalStop(reason: nil) }
            },
            onError: { [weak self] err in
                Task { @MainActor in self?.handleExternalStop(reason: "\(err)") }
            }
        )
        self.vmDelegate = forwarder
        await vm.setDelegate(forwarder)
    }

    private func handleExternalStop(reason: String?) {
        // Guard: if we're already in a controlled shutdown, the explicit
        // shutdown() path owns the transition — don't double-update.
        if case .shuttingDown = status { return }
        if case .stopped = status { return }

        vmDelegate = nil
        vm = nil
        if let reason {
            status = .crashed(reason: reason)
            lastError = reason
        } else {
            status = .stopped
        }
    }

    public func shutdown() async {
        status = .shuttingDown
        vmDelegate = nil
        if let vm = self.vm {
            await vm.setDelegate(nil)
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
    /// --iso`). Stale sidecars pointing at deleted/moved/temp files are
    /// silently cleared — VZ would fail with POSIX 45 (Operation not
    /// supported) on a missing volume, and forcing the user to diagnose
    /// that is hostile when the fix is "just boot without the CD-ROM."
    private func pendingCDROM() -> URL? {
        let sidecar = bundle.rootURL.appendingPathComponent("pending-iso.path")
        guard let data = try? Data(contentsOf: sidecar),
              let path = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Stale sidecar — remove it so subsequent boots don't hit this path.
        try? FileManager.default.removeItem(at: sidecar)
        return nil
    }
}

/// NSObject-backed forwarder for `VZVirtualMachineDelegate`. VZ calls the
/// delegate methods on the queue it owns, so we capture `@Sendable`
/// closures and trampoline back to the main actor where the session's
/// `@Observable` state lives. Marked `@unchecked Sendable` because its
/// only state is the closures themselves (which are Sendable).
final class VMStopForwarder: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let onGuestStop: @Sendable () -> Void
    private let onError: @Sendable (any Error) -> Void

    init(
        onGuestStop: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) {
        self.onGuestStop = onGuestStop
        self.onError = onError
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onGuestStop()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        onError(error)
    }
}
