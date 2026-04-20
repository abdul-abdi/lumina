// Tests/LuminaDesktopKitTests/LuminaDesktopKitTests.swift

import Testing
@testable import LuminaDesktopKit

@Test func moduleVersionIsV070() {
    #expect(LuminaDesktopKit.version.hasPrefix("0.7"))
}

@MainActor
@Test func virtualMachineViewIsConstructible() {
    // Can instantiate without a live VM — the M3 boot-and-render test
    // lives in the app-level smoke tests (not unit-testable).
    let view = LuminaVirtualMachineView()
    #expect(view.virtualMachine == nil)
    #expect(view.capturesSystemKeys == false)
}
