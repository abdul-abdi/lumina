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
        injectPreseed: { _, _ in
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
            injectPreseed: { _, original in
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
            injectPreseed: { _, _ in
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
