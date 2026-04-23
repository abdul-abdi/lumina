// Tests/LuminaDesktopKitTests/BootWaterfallViewTests.swift
//
// Unit tests for BootWaterfallView — the v0.7.1 feature 3.2
// per-phase boot-time visualization. Swift-testing doesn't render
// SwiftUI, so these tests cover the pure-logic parts: the row-
// filtering rule (zero-ms phases elided) and the isValid gate
// (empty BootPhases renders nothing).

import Foundation
import Testing
@testable import LuminaDesktopKit
import Lumina

@Suite @MainActor struct BootWaterfallViewTests {

    // MARK: - Row filtering

    @Test func rowsOmitZeroPhases() {
        // EFI path populates configMs/vzStartMs/totalMs only; the four
        // agent-path phases stay zero. Waterfall must elide zeros so
        // an EFI trace is 2 rows, not 6 with half empty.
        var phases = BootPhases()
        phases.configMs = 30
        phases.vzStartMs = 80
        phases.totalMs = 110

        let view = BootWaterfallView(phases: phases)
        let labels = view.rows.map(\.label)
        #expect(labels == ["config build", "vz start"])
    }

    @Test func rowsPreserveOrder() {
        // Boot-order is meaningful — a user scanning the waterfall
        // expects image → clone → config → vz → vsock → agent → net.
        // Any reorder would make the visualization confusing.
        var phases = BootPhases()
        phases.imageResolveMs = 5
        phases.cloneMs = 12
        phases.configMs = 30
        phases.vzStartMs = 80
        phases.vsockConnectMs = 100
        phases.runnerReadyMs = 200
        phases.networkConfigMs = 50
        phases.totalMs = 477

        let view = BootWaterfallView(phases: phases)
        #expect(view.rows.map(\.label) == [
            "image resolve", "disk clone", "config build", "vz start",
            "vsock connect", "guest agent ready", "guest network",
        ])
    }

    @Test func rowsEmptyForInvalidPhases() {
        // Fresh BootPhases is all zeros. isValid returns false;
        // rows returns an empty array.
        let view = BootWaterfallView(phases: BootPhases())
        #expect(view.rows.isEmpty)
    }

    // MARK: - isValid gate passthrough

    @Test func freshPhasesAreInvalid() {
        // Regression guard: if BootPhases.isValid changes semantics
        // the waterfall's empty-render path breaks silently. This
        // duplicates the Lumina-level test intentionally — the UI
        // behavior depends on the library's invariant.
        #expect(BootPhases().isValid == false)
    }

    @Test func singlePopulatedPhaseIsValid() {
        var phases = BootPhases()
        phases.vzStartMs = 42
        #expect(phases.isValid == true)
    }
}
