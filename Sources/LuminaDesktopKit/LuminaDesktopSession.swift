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

        /// True when `boot()` should actually start a new VZ machine.
        /// Used as the re-entry guard at the top of `boot()` to make
        /// concurrent boot calls idempotent from every UI path (card
        /// ▶ BOOT, ⌘K launcher, VM-window `.task`, menu bar). Two paths
        /// firing for a single user click would each build a
        /// `VZVirtualMachine` pointing at the same `disk.img`; VZ rejects
        /// the second attachment with `VZErrorDomain Code 2`. Returning
        /// early when not bootable prevents the race at source. Issue #14.
        public var canBoot: Bool {
            switch self {
            case .stopped, .crashed: return true
            case .booting, .running, .paused, .shuttingDown: return false
            }
        }

        /// True when a terminal-state guard should early-return in
        /// `handleExternalStop`. `.shuttingDown` means the explicit
        /// `shutdown()` path owns the transition; `.stopped` means we
        /// already landed there. Without this guard the VZ delegate
        /// callback during user-initiated stop would double-update
        /// `status` and produce the "Crashed: (null)" flash. Issue #14.
        public var isTerminal: Bool {
            switch self {
            case .stopped, .shuttingDown: return true
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

    /// VZ machine handle, observable so `RunningVMView` renders the
    /// framebuffer the moment it's available. Owned by the session,
    /// not by the view — this keeps plumbing out of SwiftUI's
    /// `@State` + `.onChange` + `Task` lifecycle, which is fragile
    /// because SwiftUI can cancel the observer's Task before it
    /// completes its actor hop.
    public var vzMachine: VZVirtualMachine?

    /// The underlying VM actor. MainActor-isolated (inherits from the
    /// enclosing `@MainActor` class). `VM` is an actor, so `VM?` is
    /// `Sendable` and can be awaited from any isolation without friction.
    private var vm: VM?

    /// Forwarder keeping `VZVirtualMachineDelegate` callbacks alive.
    /// VZ holds the delegate weakly, so we retain it here until the
    /// session is torn down.
    private var vmDelegate: VMStopForwarder?

    /// Polling task that mirrors `VM.serialTail(...)` into
    /// `serialDigest` for the booting / crashed tail UI. Lives for as
    /// long as the VM actor is attached; cancelled in `shutdown()` /
    /// `handleExternalStop()`.
    private var serialMirrorTask: Task<Void, Never>?

    public init(bundle: VMBundle) {
        self.id = bundle.manifest.id
        self.bundle = bundle
    }

    public func boot() async {
        // Re-entry guard — see `Status.canBoot` for the full rationale.
        guard status.canBoot else { return }

        status = .booting
        lastError = nil
        let start = ContinuousClock.now

        // Reload the bundle from disk so we see any manifest mutations
        // persisted by prior boots: MAC backfill, lastBootedAt update,
        // rename via `jq`, etc. Without this reload the session's
        // in-memory `bundle` is frozen at session-creation time and
        // subsequent boots re-generate the MAC over top of a stale
        // `macAddress == nil` — defeating MAC persistence.
        //
        // If the bundle has been deleted or its manifest is corrupt,
        // fall through to the in-memory copy; `ensureMACAddress()`
        // handles the nil-manifest case and the subsequent boot call
        // will surface a real error.
        var mutableBundle = (try? VMBundle.load(from: bundle.rootURL)) ?? bundle

        // Populate the bundle's stable MAC on first boot of a pre-v0.7.1
        // bundle. Idempotent: returns the existing MAC when the manifest
        // already has one. Propagated into VMOptions below so every boot
        // of this bundle presents the same L2 identity to vmnet — this is
        // what fixes the across-reboot "DHCP autoconfig failed" class of
        // installer bugs caused by vmnet issuing a fresh lease each boot.
        // (The *first-boot* Debian-installer DHCP race is a netcfg
        // single-probe-timeout issue unfixable on the host side — the
        // workaround is "Retry network autoconfiguration" in the
        // installer's failure screen.)
        let stableMAC = mutableBundle.ensureMACAddress()

        let isWindows = mutableBundle.manifest.osFamily == .windows
        let isInstallPhase = mutableBundle.manifest.lastBootedAt == nil

        var opts = VMOptions.default
        opts.memory = mutableBundle.manifest.memoryBytes
        opts.cpuCount = mutableBundle.manifest.cpuCount
        opts.macAddress = stableMAC
        // Resolve the network provider from the manifest. Nil / .nat keep
        // the historical VZNAT path; .bridged swaps in a bridge to the
        // host LAN so the guest's DHCP goes to the user's real router
        // instead of vmnet's embedded bootpd — the only reliable fix
        // for vmnet degradation and the Debian-netcfg first-probe race
        // (user edits `manifest.json` `networkMode.mode = "bridged"` or
        // passes `--network=bridged` on `lumina desktop create`).
        opts.networkProvider = Self.networkProvider(for: mutableBundle.manifest.networkMode)
        // Persist serial output to bundle/logs/serial.log for post-mortem
        // diagnosis. When a Debian/Kali installer reaches "Network
        // autoconfiguration failed" or Windows setup prints a cryptic
        // error, this file is the ground truth for what the guest
        // actually saw. Appended on every boot with a dated delimiter.
        opts.serialLogURL = mutableBundle.logsDirectory
            .appendingPathComponent("serial.log")
        opts.bootable = .efi(EFIBootConfig(
            variableStoreURL: mutableBundle.efiVarsURL,
            primaryDisk: mutableBundle.primaryDiskURL,
            cdromISO: pendingCDROM(),
            preferUSBCDROM: isWindows,
            installPhase: isInstallPhase
        ))
        opts.graphics = GraphicsConfig(
            widthInPixels: 1920,
            heightInPixels: 1080,
            keyboardKind: .usb,
            pointingDeviceKind: .usbScreenCoordinate
        )
        opts.sound = SoundConfig(enabled: true)

        // Migrate existing bundles to the Spotlight opt-out applied at
        // VMBundle.create() time. Old bundles pre-dating that change
        // don't have the flag; touching it here is idempotent and
        // removes the indexer-lock race as a Code 2 source.
        ensureSpotlightDisabled()

        // Build and install the stop/crash observer BEFORE boot. See
        // `VM.setDelegate(_:)` for the full rationale: any guest crash
        // during the 300–500 ms kernel-boot window (panic, dracut
        // timeout, missing hardware model, Windows TPM refusal) fires
        // `didStopWithError` into whatever delegate the VZ machine has
        // at that instant. Pre-boot install guarantees the delegate is
        // live; post-boot install (prior design) leaves a gap where a
        // kernel-boot-window crash silently lands on a nil delegate and
        // the UI sits at `.running` with a dead VM.
        let forwarder = VMStopForwarder(
            onGuestStop: { [weak self] in
                Task { @MainActor in self?.handleExternalStop(reason: nil) }
            },
            onError: { [weak self] err in
                Task { @MainActor in self?.handleExternalStop(reason: "\(err)") }
            }
        )
        self.vmDelegate = forwarder

        let newVM = VM(options: opts)
        self.vm = newVM
        await newVM.setDelegate(forwarder)
        startSerialMirror(for: newVM)
        do {
            try await newVM.boot()
            // Grab the VZ handle and publish it BEFORE flipping status
            // to `.running`. Observing views read `status` AND
            // `vzMachine` in the same body — if we flipped status
            // first, the view could render the `.running` branch with a
            // nil handle and fall back to the "connecting to display…"
            // placeholder. Writing vzMachine first means both mutations
            // land in the same observation tick.
            let handle = await newVM.vzMachine()
            self.vzMachine = handle.machine
            self.status = .running
            self.bootDuration = ContinuousClock.now - start
            // Persist lastBootedAt. On the very first successful boot we
            // also detach the installer ISO sidecar — the install has
            // completed and EFI now prefers the HDD, so keeping the CD-ROM
            // mounted just clutters every card with "installer attached"
            // forever. Both writes are non-fatal.
            persistBootRecord()
        } catch {
            self.vm = nil
            self.vmDelegate = nil
            self.vzMachine = nil
            // `error` is already `LuminaError` — `VM.boot()` is typed
            // `throws(LuminaError)`, so Swift knows the concrete type in
            // this catch. `isCancellation` is a LuminaError extension.
            if error.isCancellation {
                // User clicked Stop mid-boot. The VM actor's cancellation
                // path has already torn down the VZ machine, released the
                // disk `flock()`, and closed serial pipes. Treat this as a
                // clean stop so the re-entry guard allows a retry.
                self.status = .stopped
            } else {
                self.status = .crashed(reason: "\(error)")
                self.lastError = "\(error)"
            }
        }
    }

    private func ensureSpotlightDisabled() {
        let flag = bundle.rootURL.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: flag.path) {
            try? Data().write(to: flag, options: .atomic)
        }
    }

    private func persistBootRecord() {
        let isFirstBoot = bundle.manifest.lastBootedAt == nil
        if isFirstBoot {
            let sidecar = bundle.rootURL.appendingPathComponent("pending-iso.path")
            try? FileManager.default.removeItem(at: sidecar)
        }
        var updated = bundle
        updated.manifest.lastBootedAt = Date()
        try? updated.save()
    }

    /// Map a persisted `NetworkMode` to the corresponding `NetworkProvider`.
    ///
    /// Nil → `.nat` for backward compatibility with pre-v0.7.1 bundles
    /// and for every ad-hoc-signed install: the default distribution
    /// does not carry the `com.apple.vm.networking` entitlement because
    /// macOS 14+ refuses to launch ad-hoc binaries that declare it.
    ///
    /// `.bridged` uses `VZBridgedNetworkDeviceAttachment`. Requires a
    /// signed build with the `com.apple.vm.networking` entitlement —
    /// add an Apple ID in Xcode > Settings > Accounts, open the
    /// xcodeproj, flip the target to Automatic signing with your
    /// Personal Team, add `com.apple.vm.networking` under Signing &
    /// Capabilities, Run. If the binary is missing the entitlement, VZ
    /// rejects the config at `validate()` and `VM.boot()` surfaces a
    /// `LuminaError.bootFailed` — no silent downgrade; the user flips
    /// `manifest.json.networkMode` back to `nat` or rebuilds signed.
    private static func networkProvider(for mode: NetworkMode?) -> any NetworkProvider {
        switch mode ?? .nat {
        case .nat:
            return NATNetworkProvider()
        case .bridged(let iface):
            return BridgedNetworkProvider(interfaceIdentifier: iface)
        }
    }

    private func handleExternalStop(reason: String?) {
        // Terminal-state guard — see `Status.isTerminal`. Covers both
        // the "shutdown() already owns the transition" and "already
        // stopped" cases in one name.
        if status.isTerminal { return }

        // Grab one final serial tail from the VM before we drop the
        // actor reference. On a kernel panic or EFI→kernel handoff
        // crash, this tail is the only diagnostic evidence the user
        // has; capturing it here preserves it in `serialDigest` for
        // the crashed screen.
        if let vm = self.vm {
            Task { [weak self] in
                let tail = await vm.serialTail(lines: 24)
                await MainActor.run { [weak self] in
                    self?.serialDigest = tail
                }
            }
        }
        serialMirrorTask?.cancel()
        serialMirrorTask = nil

        vmDelegate = nil
        vzMachine = nil
        vm = nil
        if let reason {
            status = .crashed(reason: reason)
            lastError = reason
        } else {
            status = .stopped
        }
    }

    /// Poll the VM's serial console tail into `serialDigest` on a
    /// ~250ms cadence. During `.booting` this feeds the bottom-docked
    /// tail view — the only diagnostic available while the framebuffer
    /// is blank (EFI → kernel handoff, early kernel messages before
    /// the graphics driver claims the display). After the framebuffer
    /// lights up the tail collapses in the UI but stays live so a
    /// later crash preserves the last-known-good diagnostic lines.
    ///
    /// **Back-pressure:** the loop captures `VM.serialVersion` each tick
    /// and short-circuits the tail+strip+publish pipeline when it hasn't
    /// changed since the previous iteration. An idle VM (no new serial
    /// output — common on a quiescent `.booting` waiting on DHCP or a
    /// `.crashed` post-mortem) ends up doing one actor hop + one
    /// `UInt64` read + one equality check per 250ms tick instead of
    /// copying the megabyte ring buffer and running it through the ANSI
    /// stripper. This keeps SwiftUI's differ from spinning on identical
    /// strings for seconds at a time. Issue #27.
    private func startSerialMirror(for vm: VM) {
        serialMirrorTask?.cancel()
        serialMirrorTask = Task { [weak self] in
            var lastVersion: UInt64 = 0
            while !Task.isCancelled {
                let version = await vm.serialVersion
                if version != lastVersion {
                    lastVersion = version
                    let tail = await vm.serialTail(lines: 12)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if self.serialDigest != tail {
                            self.serialDigest = tail
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    public func shutdown() async {
        status = .shuttingDown
        // Clear the handle immediately so the view stops rendering
        // into a VZ machine that's about to tear down. The framebuffer
        // branch falls back to the stopped screen in the same tick.
        vzMachine = nil
        vmDelegate = nil
        serialMirrorTask?.cancel()
        serialMirrorTask = nil
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
