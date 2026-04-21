// Tests/LuminaGraphicsTests/GraphicsConfigTests.swift
//
// Covers the public factories in LuminaGraphics. The VZ-level wiring
// (GraphicsConfig → VZVirtualMachineConfiguration) is tested at the
// VM-actor integration level in LuminaTests/IntegrationTests, behind
// LUMINA_INTEGRATION_TESTS=1.

import Testing
@testable import LuminaGraphics
import Lumina

@Test func moduleVersionIsV070() {
    #expect(LuminaGraphics.version.hasPrefix("0.7"))
}

@Test func defaultDesktopIs1080p() {
    let g = GraphicsConfig.defaultDesktop
    #expect(g.widthInPixels == 1920)
    #expect(g.heightInPixels == 1080)
    #expect(g.keyboardKind == .usb)
    #expect(g.pointingDeviceKind == .usbScreenCoordinate)
}

@Test func compactIs720p() {
    let g = GraphicsConfig.compact
    #expect(g.widthInPixels == 1280)
    #expect(g.heightInPixels == 720)
}

@Test func fourKIs2160p() {
    let g = GraphicsConfig.fourK
    #expect(g.widthInPixels == 3840)
    #expect(g.heightInPixels == 2160)
}

@Test func resolutionFactoryHonorsArguments() {
    let g = GraphicsConfig.resolution(width: 1440, height: 900)
    #expect(g.widthInPixels == 1440)
    #expect(g.heightInPixels == 900)
    #expect(g.keyboardKind == .usb)
}

@Test func macGuestUsesMacInputDevices() {
    let g = GraphicsConfig.macGuest
    #expect(g.keyboardKind == .mac)
    #expect(g.pointingDeviceKind == .trackpad)
    // M5 pairs this with VZMacOSVirtualMachine, which is where Mac devices actually apply.
}

// MARK: - Agent-path protection

@Test func vmOptionsGraphicsDefaultsToNil() {
    // Critical invariant: the agent path must default to graphics=nil.
    // The CI boot-regression gate depends on this.
    let opts = VMOptions.default
    #expect(opts.graphics == nil)
}

@Test func vmOptionsFromRunOptionsNeverHasGraphics() {
    // Disposable `lumina run` is never a desktop workload.
    let runOpts = RunOptions.default
    let vmOpts = VMOptions(from: runOpts)
    #expect(vmOpts.graphics == nil)
}
