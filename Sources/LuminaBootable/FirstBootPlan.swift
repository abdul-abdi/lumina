// Pure orchestration of the install-time seeds we apply on the first boot
// of a desktop VM bundle. Both the CLI (`lumina desktop boot`) and the
// GUI (`LuminaDesktopSession.boot()`) call this — without a single
// shared entry point, the GUI silently bypassed the fixes the CLI was
//
// Shape:
//   - `prepareFirstBoot(...)` returns a `FirstBootPlan` value (artifacts
//     to plug into `EFIBootConfig`, plus a `[Event]` list for diagnostic
//     surfaces).
//   - Side-effecting helpers (`LinuxISOExtractor`, `PreseedSeed`,
//     `AutounattendSeed`) are reached through `FirstBootDependencies`
//     so unit tests can swap them. Production callers pass
//     `.live` (or omit, which defaults to `.live`).
//   - Fatal misconfigurations (Debian first-boot with no ISO,
//     `--capture-serial` with an unknown layout) `throw`. Recoverable
//     failures (preseed/autounattend generator errors, unknown layout
//     in non-capture mode) emit an `Event` and the plan continues.

import Foundation
import Lumina

public struct FirstBootPlan: Sendable, Equatable {
    public var linuxDirectKernel: URL?
    public var linuxDirectInitramfs: URL?
    public var linuxDirectCmdline: String?
    public var seedISOs: [URL]
    public var events: [Event]

    public enum Event: Sendable, Equatable {
        case linuxDirectMatched(layoutName: String)
        /// Extractor returned `unknownLayout` and the caller is NOT in
        /// `--capture-serial` mode, so we fell back to standard EFI boot
        /// rather than throwing. `triedPaths` is the empty-but-checked
        /// member list from `bsdtar -tf`; surfaced for diagnostics.
        case linuxDirectUnknownLayoutFallback(triedPaths: [String], supported: [String])
        /// Extractor failed for a non-`unknownLayout` reason and we fell
        /// back to standard EFI boot.
        case linuxDirectExtractFailed(reason: String)
        /// Preseed cpio.gz appended to the patched initrd. The
        /// `auto=true ... preseed/file=/preseed.cfg` cmdline flags are
        /// in `linuxDirectCmdline`.
        case preseedInjected(initrd: URL)
        /// Preseed injection failed; we kept the unpatched initrd and
        /// the user will see d-i's "DHCP autoconfig failed" screen.
        case preseedFailed(reason: String)
        /// `autounattend.iso` written + appended to `seedISOs`.
        case autounattendGenerated(iso: URL)
        /// Autounattend generation failed; Win11 Setup will hit the
        /// compat check.
        case autounattendFailed(reason: String)
        case seedAttached(iso: URL)
        case seedFailed(reason: String)
    }

    public static let empty = FirstBootPlan(
        linuxDirectKernel: nil,
        linuxDirectInitramfs: nil,
        linuxDirectCmdline: nil,
        seedISOs: [],
        events: []
    )
}

public enum FirstBootError: Swift.Error, Equatable, CustomStringConvertible {
    /// Debian/Kali/Ubuntu first boot reached the orchestrator without a
    /// pending ISO sidecar OR `--capture-serial` was requested without
    /// one. Both are fatal — there is no kernel to extract.
    case missingISO(reason: String)
    /// `--capture-serial` mode hit an unknown layout in `LinuxISOExtractor`.
    /// Fatal because the caller explicitly asked for serial-direct boot
    /// and the only way to provide it is through layout match.
    case unknownLayout(triedPaths: [String], supported: [String])

    public var description: String {
        switch self {
        case .missingISO(let r): return "missing ISO: \(r)"
        case .unknownLayout(let tried, let sup):
            return "unknown ISO layout. Tried: \(tried.joined(separator: ", ")). Supported: \(sup.joined(separator: ", "))."
        }
    }
}

public struct FirstBootDependencies: Sendable {
    public typealias Extractor = @Sendable (_ iso: URL, _ destination: URL) throws -> LinuxISOExtractor.Extracted
    /// Caller picks the preseed body via the `cfg` parameter (Debian
    /// vs Kali mirror lines, etc.) — the closure just runs cpio + cat.
    public typealias Preseeder = @Sendable (_ bundleRoot: URL, _ originalInitrd: URL, _ cfg: String) throws -> URL
    public typealias Autounattender = @Sendable (_ bundleRoot: URL) throws -> URL

    public var extract: Extractor
    public var injectPreseed: Preseeder
    public var generateAutounattend: Autounattender
    public var windowsDrivers: @Sendable () -> URL?

    public init(
        extract: @escaping Extractor,
        injectPreseed: @escaping Preseeder,
        generateAutounattend: @escaping Autounattender,
        windowsDrivers: @escaping @Sendable () -> URL? = { nil }
    ) {
        self.extract = extract
        self.injectPreseed = injectPreseed
        self.generateAutounattend = generateAutounattend
        self.windowsDrivers = windowsDrivers
    }

    public static let live = FirstBootDependencies(
        extract: { iso, destination in
            try LinuxISOExtractor.extract(iso: iso, destination: destination)
        },
        injectPreseed: { bundleRoot, originalInitrd, cfg in
            try PreseedSeed(
                bundleRootURL: bundleRoot,
                originalInitrd: originalInitrd,
                preseedCfg: cfg
            ).patch()
        },
        generateAutounattend: { bundleRoot in
            try AutounattendSeed(bundleRootURL: bundleRoot).generate()
        },
        windowsDrivers: { WindowsDrivers.cachedISO }
    )
}

/// Returns a `FirstBootPlan` of artifacts + diagnostic events. Callers
/// assign the linux-direct fields and `seedISOs` into their
/// `EFIBootConfig`, and translate `events` into whatever surface they
/// want (CLI: stderr writes; GUI: boot waterfall / serial log).
///
/// `isFirstBoot` is the caller's responsibility to compute
/// (`bundle.manifest.lastBootedAt == nil`). Passed in rather than
/// derived so the boundary is explicit and testable.
public func prepareFirstBoot(
    bundle: VMBundle,
    attachedISO: URL?,
    captureSerial: Bool,
    isFirstBoot: Bool,
    dependencies: FirstBootDependencies = .live
) throws -> FirstBootPlan {
    let osVariantLower = bundle.manifest.osVariant.lowercased()
    let isDebianFamily = osVariantLower.contains("debian")
        || osVariantLower.contains("kali")
        || osVariantLower.contains("ubuntu")
    let needsLinuxDirect = captureSerial || (isDebianFamily && isFirstBoot)
    let isWindowsFirstBoot = bundle.manifest.osFamily == .windows && isFirstBoot
    let hasSeed = isFirstBoot
        && FileManager.default.fileExists(atPath: bundle.seedDirectory.path)

    if !needsLinuxDirect && !isWindowsFirstBoot && !hasSeed {
        return .empty
    }

    // First boot owns the EFI variable store. VZEFI persists boot-order
    // entries across boots; if a prior boot wrote stale entries (failed
    // Win11 Setup attempt, dead boot device, etc.) the EFI may sit at a
    // non-existent boot entry forever — user sees a black framebuffer
    // indistinguishable from a hung VM. Wipe efi.vars so VZ re-initializes
    // a fresh store on this attempt. Best-effort.
    if isFirstBoot {
        let efiVars = bundle.rootURL.appendingPathComponent("efi.vars")
        try? FileManager.default.removeItem(at: efiVars)
    }

    var plan = FirstBootPlan.empty

    if hasSeed {
        do {
            let iso = try SeedISO.make(
                directory: bundle.seedDirectory,
                volumeName: "cidata",
                at: bundle.rootURL.appendingPathComponent("cidata.iso")
            )
            plan.seedISOs.append(iso)
            plan.events.append(.seedAttached(iso: iso))
        } catch {
            plan.events.append(.seedFailed(reason: "\(error)"))
        }
    }

    if needsLinuxDirect {
        guard let iso = attachedISO else {
            // Fatal — neither caller has anything to extract from.
            throw FirstBootError.missingISO(reason: captureSerial
                ? "--capture-serial requires an attached ISO to extract kernel + initramfs from"
                : "\(bundle.manifest.osVariant) first boot needs an attached ISO for the network preseed fix")
        }

        let artifacts = bundle.rootURL.appendingPathComponent("linux-direct")
        try? FileManager.default.removeItem(at: artifacts)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        let extracted: LinuxISOExtractor.Extracted
        do {
            extracted = try dependencies.extract(iso, artifacts)
        } catch let LinuxISOExtractor.Error.unknownLayout(triedPaths) {
            let supported = LinuxISOExtractor.knownLayouts.map { $0.name }
            // capture-serial is the only fatal path — the user explicitly
            // asked for serial-direct boot and we can't deliver it.
            if captureSerial {
                throw FirstBootError.unknownLayout(triedPaths: triedPaths, supported: supported)
            }
            // Auto-preseed mode: fall back to standard EFI boot. The
            // user gets the legacy "click Retry" experience rather than
            // a hard fail.
            plan.events.append(.linuxDirectUnknownLayoutFallback(
                triedPaths: triedPaths, supported: supported
            ))
            return plan
        } catch {
            // Any other extractor failure — also recoverable to EFI in
            // auto-preseed mode. capture-serial rethrows.
            if captureSerial { throw error }
            plan.events.append(.linuxDirectExtractFailed(reason: "\(error)"))
            return plan
        }

        plan.events.append(.linuxDirectMatched(layoutName: extracted.layoutName))
        plan.linuxDirectKernel = extracted.kernel

        var initrdURL = extracted.initramfs

        // Linux uses the LAST `console=` flag as /dev/console — that's
        // where userland (d-i, login, etc.) writes. Both consoles also
        // receive the kernel ring buffer, so serial.log gets populated
        // either way.
        //
        //   captureSerial=false (auto-preseed):
        //     console=hvc0 console=tty0 → /dev/console=tty0 → d-i UI
        //     renders on the framebuffer; serial.log still captures the
        //     kernel ring buffer.
        //
        //   captureSerial=true (--capture-serial):
        //     console=tty0 console=hvc0 → /dev/console=hvc0 → d-i UI
        //     goes to serial. Framebuffer is dark — explicit tradeoff
        //     of the flag.
        //
        // earlycon=hvc0 stays in both: it provides the kernel a console
        // before init runs, so the first ~10s of boot still hit serial.log.
        var cmdlineParts: [String]
        if captureSerial {
            cmdlineParts = ["earlycon=hvc0", "console=tty0", "console=hvc0"]
        } else {
            cmdlineParts = ["earlycon=hvc0", "console=hvc0", "console=tty0"]
        }
        if !extracted.cmdlineExtra.isEmpty {
            cmdlineParts.append(extracted.cmdlineExtra)
        }

        if isDebianFamily && isFirstBoot {
            let preseedCfg = PreseedSeed.cfg(forOSVariant: bundle.manifest.osVariant)
            do {
                let patched = try dependencies.injectPreseed(
                    bundle.rootURL, extracted.initramfs, preseedCfg
                )
                initrdURL = patched
                cmdlineParts.append(PreseedSeed.cmdlinePreseedFlags)
                plan.events.append(.preseedInjected(initrd: patched))
            } catch {
                // Recoverable — fall back to the unpatched initrd.
                plan.events.append(.preseedFailed(reason: "\(error)"))
            }
        }

        plan.linuxDirectInitramfs = initrdURL
        plan.linuxDirectCmdline = cmdlineParts.joined(separator: " ")
    }

    if isWindowsFirstBoot {
        do {
            let unattendISO = try dependencies.generateAutounattend(bundle.rootURL)
            plan.seedISOs.append(unattendISO)
            plan.events.append(.autounattendGenerated(iso: unattendISO))
            if let drivers = dependencies.windowsDrivers() {
                plan.seedISOs.append(drivers)
            }
        } catch {
            // Recoverable — Win11 will hit the compat check, but we
            // still hand control to VZ rather than aborting.
            plan.events.append(.autounattendFailed(reason: "\(error)"))
        }
    }

    return plan
}

extension VMBundle {
    public var pendingISO: URL? {
        let sidecar = rootURL.appendingPathComponent("pending-iso.path")
        guard let path = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: sidecar)
            return nil
        }
        return url
    }

    public func vmOptions(cdrom: URL?, plan: FirstBootPlan) -> VMOptions {
        var opts = VMOptions.default
        opts.memory = manifest.memoryBytes
        opts.cpuCount = manifest.cpuCount
        opts.macAddress = manifest.macAddress
        switch manifest.networkMode ?? .nat {
        case .nat: opts.networkProvider = NATNetworkProvider()
        case .bridged(let iface): opts.networkProvider = BridgedNetworkProvider(interfaceIdentifier: iface)
        }
        opts.serialLogURL = logsDirectory.appendingPathComponent("serial.log")
        opts.efi = EFIBootConfig(
            variableStoreURL: efiVarsURL,
            primaryDisk: primaryDiskURL,
            cdromISO: cdrom,
            preferUSBCDROM: manifest.osFamily == .windows,
            installPhase: manifest.lastBootedAt == nil,
            primaryDiskNVMe: manifest.osFamily == .windows,
            linuxDirectKernel: plan.linuxDirectKernel,
            linuxDirectInitramfs: plan.linuxDirectInitramfs,
            linuxDirectCmdline: plan.linuxDirectCmdline,
            extraCDROMs: plan.seedISOs
        )
        return opts
    }
}
