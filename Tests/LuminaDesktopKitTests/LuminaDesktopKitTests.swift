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

// MARK: - Status accessors (issue #14)

@Suite struct SessionStatusAccessorsTests {
    @Test func canBoot_trueOnlyForStoppedAndCrashed() {
        #expect(LuminaDesktopSession.Status.stopped.canBoot)
        #expect(LuminaDesktopSession.Status.crashed(reason: "boom").canBoot)
        #expect(!LuminaDesktopSession.Status.booting.canBoot)
        #expect(!LuminaDesktopSession.Status.running.canBoot)
        #expect(!LuminaDesktopSession.Status.paused.canBoot)
        #expect(!LuminaDesktopSession.Status.shuttingDown.canBoot)
    }

    @Test func isTerminal_trueForStoppedAndShuttingDown() {
        #expect(LuminaDesktopSession.Status.stopped.isTerminal)
        #expect(LuminaDesktopSession.Status.shuttingDown.isTerminal)
        #expect(!LuminaDesktopSession.Status.booting.isTerminal)
        #expect(!LuminaDesktopSession.Status.running.isTerminal)
        #expect(!LuminaDesktopSession.Status.paused.isTerminal)
        #expect(!LuminaDesktopSession.Status.crashed(reason: "x").isTerminal)
    }

    @Test func isLive_trueForBootingRunningPaused() {
        #expect(!LuminaDesktopSession.Status.stopped.isLive)
        #expect(LuminaDesktopSession.Status.booting.isLive)
        #expect(LuminaDesktopSession.Status.running.isLive)
        #expect(LuminaDesktopSession.Status.paused.isLive)
        #expect(!LuminaDesktopSession.Status.shuttingDown.isLive)
        #expect(!LuminaDesktopSession.Status.crashed(reason: "x").isLive)
    }
}
