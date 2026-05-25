// Tests/LuminaBootableTests/FirstBootPlanTests.swift
//
// `prepareFirstBoot(...)` is the pure orchestration that decides which
// install-time seeds to apply on the first boot of a desktop VM bundle.
// Tests use injected dependency closures so we don't need real ISOs,
// cpio, or hdiutil at unit-test time. The side-effecting tools are
// covered by their own integration tests (`PreseedSeed`,
// `AutounattendSeed`, `LinuxISOExtractor`).

import Foundation
import Testing
@testable import LuminaBootable

@Suite struct FirstBootPlanTests {

    // MARK: - Test fixtures

    /// Produce an in-memory bundle that lives under a freshly-created tmp
    /// directory. Caller is responsible for cleanup if they touch the FS.
    private func makeBundle(
        osFamily: OSFamily,
        osVariant: String,
        isFirstBoot: Bool = true
    ) throws -> VMBundle {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumina-first-boot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = VMBundleManifest(
            id: UUID(),
            name: "test",
            osFamily: osFamily,
            osVariant: osVariant,
            memoryBytes: 2 * 1024 * 1024 * 1024,
            cpuCount: 2,
            diskBytes: 8 * 1024 * 1024 * 1024,
            createdAt: Date(timeIntervalSince1970: 0),
            lastBootedAt: isFirstBoot ? nil : Date(timeIntervalSince1970: 100)
        )
        return VMBundle(rootURL: tmp, manifest: manifest)
    }

    /// Default test deps that fail loudly if called — each test overrides
    /// only what it needs. Catches "the orchestrator dispatched to a
    /// helper it shouldn't have" silently.
    private static let unreachableDeps = FirstBootDependencies(
        extract: { _, _ in
            Issue.record("extract was called but the test did not expect it")
            throw NSError(domain: "test", code: 1)
        },
        injectPreseed: { _, _, _ in
            Issue.record("injectPreseed was called but the test did not expect it")
            throw NSError(domain: "test", code: 1)
        },
        generateAutounattend: { _ in
            Issue.record("generateAutounattend was called but the test did not expect it")
            throw NSError(domain: "test", code: 1)
        }
    )

    // MARK: - Tests

    @Test func nonDebianLinux_firstBoot_noCapture_returnsEmptyPlan() throws {
        let bundle = try makeBundle(osFamily: .linux, osVariant: "fedora-39")
        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: nil,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: Self.unreachableDeps
        )
        #expect(plan.linuxDirectKernel == nil)
        #expect(plan.linuxDirectInitramfs == nil)
        #expect(plan.linuxDirectCmdline == nil)
        #expect(plan.extraDisks.isEmpty)
        #expect(plan.events.isEmpty)
    }

    @Test func debian_firstBoot_withISO_extractAndPreseedSucceed() throws {
        let bundle = try makeBundle(osFamily: .linux, osVariant: "debian-12")
        let iso = URL(fileURLWithPath: "/fake/debian.iso")
        let extractedKernel = URL(fileURLWithPath: "/fake/extracted/vmlinuz")
        let extractedInitrd = URL(fileURLWithPath: "/fake/extracted/initrd.gz")
        let patchedInitrd = URL(fileURLWithPath: "/fake/bundle/initrd.preseeded")

        let deps = FirstBootDependencies(
            extract: { _, _ in
                LinuxISOExtractor.Extracted(
                    kernel: extractedKernel,
                    initramfs: extractedInitrd,
                    layoutName: "Debian arm64 netinst",
                    cmdlineExtra: ""
                )
            },
            injectPreseed: { _, original, _ in
                #expect(original == extractedInitrd, "preseed must run on the extracted initrd, not a different file")
                return patchedInitrd
            },
            generateAutounattend: { _ in
                Issue.record("autounattend must not be generated for a linux bundle")
                throw NSError(domain: "test", code: 1)
            }
        )

        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: iso,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: deps
        )

        #expect(plan.linuxDirectKernel == extractedKernel)
        #expect(plan.linuxDirectInitramfs == patchedInitrd)
        // cmdline must include the hvc0 console + the preseed flags. We
        // assert presence-of-substring rather than exact equality so the
        // contract is "it contains these critical pieces" rather than
        // "the joiner uses one space"; that keeps the test robust to
        // future cmdline tweaks.
        let cmdline = try #require(plan.linuxDirectCmdline)
        #expect(cmdline.contains("console=hvc0"))
        #expect(cmdline.contains("earlycon=hvc0"))
        #expect(cmdline.contains("auto=true"))
        #expect(cmdline.contains("preseed/file=/preseed.cfg"))

        #expect(plan.extraDisks.isEmpty)
        #expect(plan.events.contains(.linuxDirectMatched(layoutName: "Debian arm64 netinst")))
        #expect(plan.events.contains(.preseedInjected(initrd: patchedInitrd)))
    }

    @Test func debian_firstBoot_noISO_throwsMissingISO() throws {
        let bundle = try makeBundle(osFamily: .linux, osVariant: "debian-12")
        do {
            _ = try prepareFirstBoot(
                bundle: bundle,
                attachedISO: nil,
                captureSerial: false,
                isFirstBoot: true,
                dependencies: Self.unreachableDeps
            )
            Issue.record("expected throw, got plan")
        } catch let error as FirstBootError {
            switch error {
            case .missingISO: break // expected
            default: Issue.record("expected .missingISO, got \(error)")
            }
        }
    }

    @Test func debian_firstBoot_unknownLayout_fallsBackToEFI() throws {
        // Non-capture mode: extractor reports unknownLayout. Orchestrator
        // must NOT throw; it must record the fallback event and return
        // an otherwise-empty plan so the caller's EFI path takes over.
        // We check the preseeder is never invoked since the kernel +
        // initrd never came back.
        let bundle = try makeBundle(osFamily: .linux, osVariant: "debian-12")
        let iso = URL(fileURLWithPath: "/fake/debian.iso")
        let deps = FirstBootDependencies(
            extract: { _, _ in
                throw LinuxISOExtractor.Error.unknownLayout(triedPaths: ["foo/vmlinuz", "bar/vmlinuz"])
            },
            injectPreseed: { _, _, _ in
                Issue.record("preseed must not be called when extract failed")
                throw NSError(domain: "test", code: 1)
            },
            generateAutounattend: Self.unreachableDeps.generateAutounattend
        )

        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: iso,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: deps
        )

        #expect(plan.linuxDirectKernel == nil)
        #expect(plan.linuxDirectInitramfs == nil)
        #expect(plan.linuxDirectCmdline == nil)
        // Exactly one event of the fallback case.
        if case .linuxDirectUnknownLayoutFallback(let tried, _) = plan.events.first {
            #expect(tried == ["foo/vmlinuz", "bar/vmlinuz"])
        } else {
            Issue.record("expected linuxDirectUnknownLayoutFallback as first event, got \(plan.events)")
        }
    }

    @Test func captureSerial_unknownLayout_throwsUnknownLayout() throws {
        // capture-serial is the user explicitly asking for serial-direct
        // boot. If we can't deliver it, that's fatal — fallback to EFI
        // would silently produce 0 bytes of serial output, which is
        // exactly the failure mode --capture-serial exists to fix.
        let bundle = try makeBundle(osFamily: .linux, osVariant: "fedora-39")
        let iso = URL(fileURLWithPath: "/fake/fedora.iso")
        let deps = FirstBootDependencies(
            extract: { _, _ in
                throw LinuxISOExtractor.Error.unknownLayout(triedPaths: ["weird/vmlinuz"])
            },
            injectPreseed: Self.unreachableDeps.injectPreseed,
            generateAutounattend: Self.unreachableDeps.generateAutounattend
        )
        do {
            _ = try prepareFirstBoot(
                bundle: bundle,
                attachedISO: iso,
                captureSerial: true,
                isFirstBoot: true,
                dependencies: deps
            )
            Issue.record("expected throw, got plan")
        } catch let error as FirstBootError {
            switch error {
            case .unknownLayout(let tried, _):
                #expect(tried == ["weird/vmlinuz"])
            default:
                Issue.record("expected .unknownLayout, got \(error)")
            }
        }
    }

    @Test func windows_firstBoot_generatesAutounattend() throws {
        let bundle = try makeBundle(osFamily: .windows, osVariant: "windows-11-arm")
        let unattendISO = URL(fileURLWithPath: "/fake/bundle/autounattend.iso")
        let deps = FirstBootDependencies(
            extract: Self.unreachableDeps.extract,
            injectPreseed: Self.unreachableDeps.injectPreseed,
            generateAutounattend: { _ in unattendISO }
        )
        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: nil,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: deps
        )
        #expect(plan.linuxDirectKernel == nil)
        #expect(plan.extraDisks == [unattendISO])
        #expect(plan.events.contains(.autounattendGenerated(iso: unattendISO)))
    }

    @Test func windows_firstBoot_autounattendFailureIsRecoverable() throws {
        // Win11 setup will hit the compat check, but we still hand
        // control to VZ so the user at least sees what's happening
        // rather than the orchestrator throwing before boot.
        let bundle = try makeBundle(osFamily: .windows, osVariant: "windows-11-arm")
        let deps = FirstBootDependencies(
            extract: Self.unreachableDeps.extract,
            injectPreseed: Self.unreachableDeps.injectPreseed,
            generateAutounattend: { _ in
                throw AutounattendSeed.Error.hdiutilNotAvailable
            }
        )
        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: nil,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: deps
        )
        #expect(plan.extraDisks.isEmpty)
        if case .autounattendFailed = plan.events.first {
            // expected
        } else {
            Issue.record("expected .autounattendFailed event, got \(plan.events)")
        }
    }

    /// Single-shot capture box for closure observation in tests.
    /// `@unchecked Sendable` is fine here because each `prepareFirstBoot`
    /// call we make in tests is fully synchronous — the closure runs
    /// inline before `prepareFirstBoot` returns.
    private final class Capture<T>: @unchecked Sendable {
        var value: T?
    }

    @Test func debian_firstBoot_routesPrimaryConsoleToFramebuffer() throws {
        // Linux uses the LAST `console=` flag as /dev/console — that's
        // where the userland text UI (d-i) goes. We need tty0 (the
        // virtio framebuffer) to be primary so the user can see the
        // installer; hvc0 stays in the list so the kernel ring buffer
        // also reaches serial.log for diagnostics.
        let bundle = try makeBundle(osFamily: .linux, osVariant: "debian-12")
        let iso = URL(fileURLWithPath: "/fake/debian.iso")
        let deps = FirstBootDependencies(
            extract: { _, _ in
                LinuxISOExtractor.Extracted(
                    kernel: URL(fileURLWithPath: "/fake/k"),
                    initramfs: URL(fileURLWithPath: "/fake/i"),
                    layoutName: "Debian arm64 netinst",
                    cmdlineExtra: ""
                )
            },
            injectPreseed: { _, _, _ in URL(fileURLWithPath: "/fake/initrd.preseeded") },
            generateAutounattend: Self.unreachableDeps.generateAutounattend
        )
        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: iso,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: deps
        )
        let cmdline = try #require(plan.linuxDirectCmdline)
        // Order matters. Last console= wins as /dev/console.
        let hvc0Range = cmdline.range(of: "console=hvc0")
        let tty0Range = cmdline.range(of: "console=tty0")
        let hvc0 = try #require(hvc0Range)
        let tty0 = try #require(tty0Range)
        #expect(hvc0.lowerBound < tty0.lowerBound, "console=tty0 must come AFTER console=hvc0 so the framebuffer is the userland console")
    }

    @Test func captureSerial_routesPrimaryConsoleToSerial() throws {
        // --capture-serial is the explicit "I want serial-direct boot"
        // flag — the framebuffer staying dark is the documented
        // tradeoff. /dev/console must be hvc0 here.
        let bundle = try makeBundle(osFamily: .linux, osVariant: "fedora-39")
        let iso = URL(fileURLWithPath: "/fake/fedora.iso")
        let deps = FirstBootDependencies(
            extract: { _, _ in
                LinuxISOExtractor.Extracted(
                    kernel: URL(fileURLWithPath: "/fake/k"),
                    initramfs: URL(fileURLWithPath: "/fake/i"),
                    layoutName: "Fedora Live",
                    cmdlineExtra: ""
                )
            },
            injectPreseed: Self.unreachableDeps.injectPreseed,
            generateAutounattend: Self.unreachableDeps.generateAutounattend
        )
        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: iso,
            captureSerial: true,
            isFirstBoot: true,
            dependencies: deps
        )
        let cmdline = try #require(plan.linuxDirectCmdline)
        let hvc0Range = cmdline.range(of: "console=hvc0")
        let tty0Range = cmdline.range(of: "console=tty0")
        let hvc0 = try #require(hvc0Range)
        let tty0 = try #require(tty0Range)
        #expect(tty0.lowerBound < hvc0.lowerBound, "for --capture-serial, console=hvc0 must come last so /dev/console=hvc0")
    }

    @Test func kali_firstBoot_usesKaliMirrorInPreseed() throws {
        // The default Debian preseed points at deb.debian.org which
        // doesn't host Kali suites — install fails mid-APT. The
        // orchestrator must select the Kali-flavoured preseed when the
        // osVariant matches Kali.
        let bundle = try makeBundle(osFamily: .linux, osVariant: "kali-rolling")
        let iso = URL(fileURLWithPath: "/fake/kali.iso")

        let seen = Capture<String>()
        let deps = FirstBootDependencies(
            extract: { _, _ in
                LinuxISOExtractor.Extracted(
                    kernel: URL(fileURLWithPath: "/fake/k"),
                    initramfs: URL(fileURLWithPath: "/fake/i"),
                    layoutName: "Debian arm64 netinst",
                    cmdlineExtra: ""
                )
            },
            injectPreseed: { _, _, cfg in
                seen.value = cfg
                return URL(fileURLWithPath: "/fake/initrd.preseeded")
            },
            generateAutounattend: Self.unreachableDeps.generateAutounattend
        )

        _ = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: iso,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: deps
        )

        let cfg = try #require(seen.value)
        #expect(cfg.contains("http.kali.org"), "Kali preseed must use the Kali mirror, not deb.debian.org")
        #expect(cfg.contains("netcfg/dhcp_retries string 4"), "Kali still needs the DHCP-retries fix")
        #expect(!cfg.contains("deb.debian.org"), "Kali preseed must not reference the Debian mirror")
    }

    @Test func debian_firstBoot_usesDebianMirrorInPreseed() throws {
        // Companion to kali_firstBoot_usesKaliMirrorInPreseed: ensure
        // Debian still gets deb.debian.org (regression guard if someone
        // flips the dispatch the wrong way later).
        let bundle = try makeBundle(osFamily: .linux, osVariant: "debian-12")
        let iso = URL(fileURLWithPath: "/fake/debian.iso")

        let seen = Capture<String>()
        let deps = FirstBootDependencies(
            extract: { _, _ in
                LinuxISOExtractor.Extracted(
                    kernel: URL(fileURLWithPath: "/fake/k"),
                    initramfs: URL(fileURLWithPath: "/fake/i"),
                    layoutName: "Debian arm64 netinst",
                    cmdlineExtra: ""
                )
            },
            injectPreseed: { _, _, cfg in
                seen.value = cfg
                return URL(fileURLWithPath: "/fake/initrd.preseeded")
            },
            generateAutounattend: Self.unreachableDeps.generateAutounattend
        )

        _ = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: iso,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: deps
        )

        let cfg = try #require(seen.value)
        #expect(cfg.contains("deb.debian.org"))
        #expect(!cfg.contains("http.kali.org"))
    }

    @Test func firstBoot_resetsEFIVarStore() throws {
        // VZEFI persists boot-order + boot-device entries to the
        // efi.vars store across boots. If a prior boot wrote stale
        // entries (Win11 Setup partial-install attempt, dead boot
        // device, etc.), the EFI may sit at a non-existent boot
        // entry on the next attempt and never reach the kernel —
        // user sees a black framebuffer indistinguishable from a
        // hung VM. First boot owns this state — wipe it so EFI
        // re-discovers boot devices from scratch.
        let bundle = try makeBundle(osFamily: .windows, osVariant: "windows-11-arm")
        // Pre-write a 64-byte stub at efi.vars to simulate stale state.
        let efiVars = bundle.rootURL.appendingPathComponent("efi.vars")
        try Data(repeating: 0xAB, count: 64).write(to: efiVars)
        #expect(FileManager.default.fileExists(atPath: efiVars.path))

        _ = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: nil,
            captureSerial: false,
            isFirstBoot: true,
            dependencies: FirstBootDependencies(
                extract: Self.unreachableDeps.extract,
                injectPreseed: Self.unreachableDeps.injectPreseed,
                generateAutounattend: { _ in URL(fileURLWithPath: "/fake/autounattend.iso") }
            )
        )
        #expect(!FileManager.default.fileExists(atPath: efiVars.path), "first boot must wipe efi.vars so VZ re-initializes a fresh store")
    }

    @Test func notFirstBoot_preservesEFIVarStore() throws {
        // The flip side — a re-boot of an installed VM must NOT
        // wipe efi.vars; that's where the post-install boot order
        // lives and we'd brick the boot loop.
        let bundle = try makeBundle(
            osFamily: .windows, osVariant: "windows-11-arm", isFirstBoot: false
        )
        let efiVars = bundle.rootURL.appendingPathComponent("efi.vars")
        let sentinel = Data([0x42, 0x61, 0x64, 0x00])
        try sentinel.write(to: efiVars)

        _ = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: nil,
            captureSerial: false,
            isFirstBoot: false,
            dependencies: Self.unreachableDeps
        )

        let after = try Data(contentsOf: efiVars)
        #expect(after == sentinel, "non-first-boot must not touch efi.vars")
    }

    @Test func notFirstBoot_skipsAllSeeds() throws {
        // Bundle has lastBootedAt set — neither preseed nor autounattend
        // should fire. Use the Windows variant since it's the most likely
        // to silently re-fire (no Linux gating). Unreachable deps prove
        // none of the helpers were called.
        let bundle = try makeBundle(
            osFamily: .windows,
            osVariant: "windows-11-arm",
            isFirstBoot: false
        )
        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: nil,
            captureSerial: false,
            isFirstBoot: false,
            dependencies: Self.unreachableDeps
        )
        #expect(plan == FirstBootPlan.empty)
    }
}
