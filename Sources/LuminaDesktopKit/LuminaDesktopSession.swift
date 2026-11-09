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

    }

    public var status: Status = .stopped
    public var lastError: String?
    public var bootDuration: Duration?
    public var serialDigest: String = ""
    public var bootPhases: BootPhases = BootPhases()
    public var installProgress: (label: String, fraction: Double)?

    public var snapshot: SessionSnapshot {
        SessionSnapshot(
            status: status,
            lastError: lastError,
            bootDuration: bootDuration,
            serialDigest: serialDigest,
            bootPhases: bootPhases
        )
    }

    /// Atomically apply a snapshot — writes every observable field in
    /// a single synchronous block so SwiftUI observers see one tick
    /// containing the full transition, not four separate ticks where
    /// status briefly desyncs from duration/error.
    ///
    /// Each field is only written when it actually differs from the
    /// current value, so idempotent applies (applyAtomic of the
    /// current snapshot) don't fire spurious observation ticks.
    public func applyAtomic(_ next: SessionSnapshot) {
        if status != next.status { status = next.status }
        if lastError != next.lastError { lastError = next.lastError }
        if bootDuration != next.bootDuration { bootDuration = next.bootDuration }
        if serialDigest != next.serialDigest { serialDigest = next.serialDigest }
        if bootPhases != next.bootPhases { bootPhases = next.bootPhases }
    }

    /// VZ machine handle, observable so `RunningVMView` renders the
    /// framebuffer the moment it's available. Owned by the session,
    /// not by the view — this keeps plumbing out of SwiftUI's
    /// `@State` + `.onChange` + `Task` lifecycle, which is fragile
    /// because SwiftUI can cancel the observer's Task before it
    /// completes its actor hop.
    public var vzMachine: VZVirtualMachine?

    private var vm: VM?
    private var macVM: MacOSVM?
    private var installTask: Task<Void, any Error>?

    /// Forwarder keeping `VZVirtualMachineDelegate` callbacks alive.
    /// VZ holds the delegate weakly, so we retain it here until the
    /// session is torn down.
    private var vmDelegate: VMStopForwarder?

    private var serialMirrorTask: Task<Void, Never>?

    /// Polling task that mirrors `VM.bootPhases` into `bootPhases` so
    /// the waterfall UI renders phase bars as they complete, not just
    /// as a post-boot snapshot. Lifecycle-scoped to a single boot: set
    /// up at boot() entry, cancelled the moment boot() returns (success
    /// or failure), because after boot completes the phases are frozen
    /// and the final `applyAtomic` is the authoritative write.
    private var bootPhasesMirrorTask: Task<Void, Never>?

    public init(bundle: VMBundle) {
        self.id = bundle.manifest.id
        self.bundle = bundle
    }

    public func boot() async {
        guard status.canBoot else { return }

        // Enter .booting with a clean error slate in a single tick.
        // Two separate assignments previously meant observers could
        // see `.booting` paired with a stale `lastError` from a prior
        // crashed boot — tiny window but a real impossible-state.
        applyAtomic(SessionSnapshot(
            status: .booting,
            lastError: nil,
            bootDuration: bootDuration,
            serialDigest: serialDigest,
            bootPhases: BootPhases()
        ))
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
        mutableBundle.ensureMACAddress()
        if mutableBundle.manifest.osFamily == .macOS {
            await bootMacOS(mutableBundle, start: start)
            return
        }

        let isInstallPhase = mutableBundle.manifest.lastBootedAt == nil
        let cdromURL = mutableBundle.pendingISO
        if mutableBundle.manifest.osFamily == .windows, isInstallPhase, WindowsDrivers.cachedISO == nil {
            _ = try? await WindowsDrivers.ensure { [weak self] fraction in
                Task { @MainActor in self?.installProgress = ("Downloading Windows drivers", fraction) }
            }
            installProgress = nil
        }

        // First-boot orchestration — preseed injection (Debian/Kali) and
        // Windows 11 autounattend sidecar. Same call the CLI makes from
        // `lumina desktop boot`. Without this, the GUI Boot button
        // bypassed both fixes and Debian d-i hit the vmnet DHCP race
        // every install. See `LuminaBootable.prepareFirstBoot`.
        //
        // Failures: `FirstBootError.missingISO` (Debian first boot with
        // no attached ISO) lands as a `.crashed` so the user sees a
        // failure card rather than the VM booting into the standard EFI
        // path with no preseed and the Retry-network-autoconfig dance.
        let firstBootPlan: FirstBootPlan
        do {
            firstBootPlan = try prepareFirstBoot(
                bundle: mutableBundle,
                attachedISO: cdromURL,
                captureSerial: false,
                isFirstBoot: isInstallPhase
            )
        } catch {
            applyAtomic(SessionSnapshot(
                status: .crashed(reason: "first-boot prep: \(error)"),
                lastError: "first-boot prep: \(error)",
                bootDuration: bootDuration,
                serialDigest: serialDigest,
                bootPhases: BootPhases()
            ))
            return
        }
        appendFirstBootLog(events: firstBootPlan.events, to: mutableBundle.logsDirectory)

        var opts = mutableBundle.vmOptions(cdrom: cdromURL, plan: firstBootPlan)
        opts.graphics = GraphicsConfig()
        opts.sound = true

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
        let forwarder = makeStopForwarder()
        self.vmDelegate = forwarder

        let newVM = VM(options: opts)
        self.vm = newVM
        await newVM.setDelegate(forwarder)
        startSerialMirror(for: newVM)
        startBootPhasesMirror(for: newVM)
        do {
            try await newVM.boot()
            bootPhasesMirrorTask?.cancel()
            bootPhasesMirrorTask = nil
            // Grab the VZ handle and publish it BEFORE flipping status
            // to `.running`. Observing views read `status` AND
            // `vzMachine` in the same body — if we flipped status
            // first, the view could render the `.running` branch with a
            // nil handle and fall back to the "connecting to display…"
            // placeholder. Writing vzMachine first means both mutations
            // land in the same observation tick.
            let handle = await newVM.vzMachine()
            self.vzMachine = handle.machine
            let phases = await newVM.bootPhases
            // Land status + bootDuration + phases in a single observation
            // tick so the UI never renders `.running` with a nil duration
            // (or the previous run's phases).
            applyAtomic(SessionSnapshot(
                status: .running,
                lastError: nil,
                bootDuration: ContinuousClock.now - start,
                serialDigest: serialDigest,
                bootPhases: phases
            ))
            try? mutableBundle.recordBoot()
        } catch {
            bootPhasesMirrorTask?.cancel()
            bootPhasesMirrorTask = nil
            let partialPhases = await self.vm?.bootPhases ?? BootPhases()
            self.vm = nil
            self.vmDelegate = nil
            self.vzMachine = nil
            if error.isCancellation {
                // User clicked Stop mid-boot. The VM actor's cancellation
                // path has already torn down the VZ machine, released the
                // disk `flock()`, and closed serial pipes. Treat this as a
                // clean stop so the re-entry guard allows a retry.
                applyAtomic(SessionSnapshot(
                    status: .stopped,
                    lastError: nil,
                    bootDuration: bootDuration,
                    serialDigest: serialDigest,
                    bootPhases: partialPhases
                ))
            } else {
                applyAtomic(SessionSnapshot(
                    status: .crashed(reason: "\(error)"),
                    lastError: "\(error)",
                    bootDuration: bootDuration,
                    serialDigest: serialDigest,
                    bootPhases: partialPhases
                ))
            }
        }
    }

    private func bootMacOS(_ bundle: VMBundle, start: ContinuousClock.Instant) async {
        var bundle = bundle
        do {
            if !bundle.isMacOSInstalled {
                let installing = bundle
                let task = Task { [weak self] in
                    var target = installing
                    try await target.installMacOS { phase, fraction in
                        let label = phase == .downloading ? "Downloading macOS" : "Installing macOS"
                        Task { @MainActor in self?.installProgress = (label, fraction) }
                    }
                }
                installTask = task
                try await task.value
                installTask = nil
                installProgress = nil
                bundle = (try? VMBundle.load(from: bundle.rootURL)) ?? bundle
            }
            ensureSpotlightDisabled()
            let forwarder = makeStopForwarder()
            vmDelegate = forwarder
            let newVM = bundle.macOSVM()
            macVM = newVM
            await newVM.setDelegate(forwarder)
            try await newVM.boot()
            vzMachine = await newVM.vzMachine().machine
            applyAtomic(SessionSnapshot(
                status: .running,
                lastError: nil,
                bootDuration: ContinuousClock.now - start,
                serialDigest: "",
                bootPhases: BootPhases()
            ))
            try? bundle.recordBoot()
        } catch {
            installTask = nil
            installProgress = nil
            macVM = nil
            vmDelegate = nil
            vzMachine = nil
            let cancelled = error is CancellationError || status == .shuttingDown || status == .stopped
            applyAtomic(SessionSnapshot(
                status: cancelled ? .stopped : .crashed(reason: "\(error)"),
                lastError: cancelled ? nil : "\(error)",
                bootDuration: bootDuration,
                serialDigest: serialDigest,
                bootPhases: BootPhases()
            ))
        }
    }

    private func makeStopForwarder() -> VMStopForwarder {
        VMStopForwarder(
            onGuestStop: { [weak self] in
                Task { @MainActor in self?.handleExternalStop(reason: nil) }
            },
            onError: { [weak self] err in
                Task { @MainActor in self?.handleExternalStop(reason: "\(err)") }
            }
        )
    }

    private func ensureSpotlightDisabled() {
        let flag = bundle.rootURL.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: flag.path) {
            try? Data().write(to: flag, options: .atomic)
        }
    }

    /// Append the orchestrator's structured event list to
    /// `<bundle>/logs/first-boot.log` as one human-readable line per
    /// event. The CLI emits these to stderr; the GUI has no equivalent,
    /// so we land them on disk where the user can `tail -f` if they
    /// hit a problem and need to see what the host did or didn't try.
    /// Best-effort — failures here never block boot.
    nonisolated private func appendFirstBootLog(
        events: [FirstBootPlan.Event],
        to logsDirectory: URL
    ) {
        guard !events.isEmpty else { return }
        let url = logsDirectory.appendingPathComponent("first-boot.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var text = "--- first-boot \(timestamp) ---\n"
        for event in events {
            text += "  " + Self.describe(event: event) + "\n"
        }
        try? FileManager.default.createDirectory(
            at: logsDirectory, withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    nonisolated private static func describe(event: FirstBootPlan.Event) -> String {
        switch event {
        case .linuxDirectMatched(let layoutName):
            return "linux-direct: matched \(layoutName)"
        case .linuxDirectUnknownLayoutFallback(let tried, _):
            return "linux-direct: unknown layout (tried \(tried.joined(separator: ", "))); fell back to EFI"
        case .linuxDirectExtractFailed(let reason):
            return "linux-direct: extract failed (\(reason)); fell back to EFI"
        case .preseedInjected(let initrd):
            return "preseed: injected /preseed.cfg into \(initrd.lastPathComponent)"
        case .preseedFailed(let reason):
            return "preseed: failed (\(reason)); booting unpatched initrd"
        case .autounattendGenerated(let iso):
            return "windows: autounattend sidecar at \(iso.lastPathComponent)"
        case .autounattendFailed(let reason):
            return "windows: autounattend failed (\(reason)); compat check will fire"
        case .seedAttached(let iso):
            return "seed: attached \(iso.lastPathComponent)"
        case .seedFailed(let reason):
            return "seed: failed (\(reason))"
        }
    }

    private func handleExternalStop(reason: String?) {
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
        bootPhasesMirrorTask?.cancel()
        bootPhasesMirrorTask = nil

        vmDelegate = nil
        vzMachine = nil
        vm = nil
        macVM = nil
        // Atomic transition — crashed(reason) must not be observed
        // without lastError populated, and stopped must not carry a
        // stale lastError from a prior crash. Single observation tick.
        if let reason {
            applyAtomic(SessionSnapshot(
                status: .crashed(reason: reason),
                lastError: reason,
                bootDuration: bootDuration,
                serialDigest: serialDigest,
                bootPhases: bootPhases
            ))
        } else {
            applyAtomic(SessionSnapshot(
                status: .stopped,
                lastError: nil,
                bootDuration: bootDuration,
                serialDigest: serialDigest,
                bootPhases: bootPhases
            ))
        }
    }

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

    /// Poll `VM.bootPhases` every 150ms and mirror non-empty snapshots
    /// into `self.bootPhases` so the waterfall UI in the booting
    /// screen fills in as each phase completes. 150ms gives the user
    /// a noticeable "filling in" motion on a 680ms cold boot without
    /// thrashing the actor. Exits cleanly on the first `applyAtomic`
    /// that would overwrite with equal values (Equatable check inside
    /// applyAtomic); caller cancels the task on boot completion.
    private func startBootPhasesMirror(for vm: VM) {
        bootPhasesMirrorTask?.cancel()
        bootPhasesMirrorTask = Task { [weak self] in
            while !Task.isCancelled {
                let phases = await vm.bootPhases
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.bootPhases != phases {
                        self.bootPhases = phases
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
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
        bootPhasesMirrorTask?.cancel()
        bootPhasesMirrorTask = nil
        installTask?.cancel()
        if let vm = self.vm {
            await vm.setDelegate(nil)
            await vm.shutdown()
        }
        if let macVM {
            await macVM.setDelegate(nil)
            await macVM.shutdown()
        }
        self.vm = nil
        self.macVM = nil
        status = .stopped
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
