// Sources/LuminaBootable/FirstBootPlan.swift
//
// Pure orchestration of the install-time seeds we apply on the first boot
// of a desktop VM bundle. Both the CLI (`lumina desktop boot`) and the
// GUI (`LuminaDesktopSession.boot()`) call this — without a single
// shared entry point, the GUI silently bypassed the fixes the CLI was
// applying. See [[wiki/projects/lumina]] for the v0.7.2 incident.
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

public struct FirstBootPlan: Sendable, Equatable {
    public var linuxDirectKernel: URL?
    public var linuxDirectInitramfs: URL?
    public var linuxDirectCmdline: String?
    public var extraDisks: [URL]
    public var events: [Event]

    public enum Event: Sendable, Equatable {
        /// `LinuxISOExtractor` matched a known layout. `layoutName` is
        /// the human-readable distro string (e.g. "Debian arm64 netinst").
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
        /// `autounattend.iso` written + appended to `extraDisks`.
        case autounattendGenerated(iso: URL)
        /// Autounattend generation failed; Win11 Setup will hit the
        /// compat check.
        case autounattendFailed(reason: String)
    }

    public static let empty = FirstBootPlan(
        linuxDirectKernel: nil,
        linuxDirectInitramfs: nil,
        linuxDirectCmdline: nil,
        extraDisks: [],
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
    public typealias Preseeder = @Sendable (_ bundleRoot: URL, _ originalInitrd: URL) throws -> URL
    public typealias Autounattender = @Sendable (_ bundleRoot: URL) throws -> URL

    public var extract: Extractor
    public var injectPreseed: Preseeder
    public var generateAutounattend: Autounattender

    public init(
        extract: @escaping Extractor,
        injectPreseed: @escaping Preseeder,
        generateAutounattend: @escaping Autounattender
    ) {
        self.extract = extract
        self.injectPreseed = injectPreseed
        self.generateAutounattend = generateAutounattend
    }

    /// Production wiring: real `LinuxISOExtractor`, `PreseedSeed`,
    /// `AutounattendSeed`.
    public static let live = FirstBootDependencies(
        extract: { iso, destination in
            try LinuxISOExtractor.extract(iso: iso, destination: destination)
        },
        injectPreseed: { bundleRoot, originalInitrd in
            try PreseedSeed(
                bundleRootURL: bundleRoot,
                originalInitrd: originalInitrd
            ).patch()
        },
        generateAutounattend: { bundleRoot in
            try AutounattendSeed(bundleRootURL: bundleRoot).generate()
        }
    )
}

/// Returns a `FirstBootPlan` of artifacts + diagnostic events. Callers
/// assign the linux-direct fields and `extraDisks` into their
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

    if !needsLinuxDirect && !isWindowsFirstBoot {
        return .empty
    }

    var plan = FirstBootPlan.empty

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

        // Default to the extracted initrd; the preseed step (if it runs)
        // overwrites this with the patched copy.
        var initrdURL = extracted.initramfs

        // earlycon=hvc0 lets the kernel start writing to virtio-serial
        // before init runs — without it the first ~10s of boot are
        // invisible. Cheap and load-bearing for capture-serial diagnosis.
        var cmdlineParts = ["console=hvc0", "earlycon=hvc0"]
        if !extracted.cmdlineExtra.isEmpty {
            cmdlineParts.append(extracted.cmdlineExtra)
        }

        if isDebianFamily && isFirstBoot {
            do {
                let patched = try dependencies.injectPreseed(bundle.rootURL, extracted.initramfs)
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
            plan.extraDisks.append(unattendISO)
            plan.events.append(.autounattendGenerated(iso: unattendISO))
        } catch {
            // Recoverable — Win11 will hit the compat check, but we
            // still hand control to VZ rather than aborting.
            plan.events.append(.autounattendFailed(reason: "\(error)"))
        }
    }

    return plan
}
