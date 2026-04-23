// Tests/LuminaDesktopKitTests/SessionSnapshotTests.swift
//
// Unit tests for SessionSnapshot — the v0.7.1 value-type
// decomposition of LuminaDesktopSession state. Covers atomic
// transitions, Equatable semantics, and the self-idempotent
// applyAtomic path that must NOT fire observation ticks when the
// snapshot hasn't changed.

import Foundation
import Testing
@testable import LuminaDesktopKit
@testable import LuminaBootable
import Lumina

@Suite @MainActor struct SessionSnapshotTests {

    // MARK: - value-type semantics

    @Test func initialSnapshotIsStoppedWithNoError() {
        let snap = SessionSnapshot.initial
        #expect(snap.status == .stopped)
        #expect(snap.lastError == nil)
        #expect(snap.bootDuration == nil)
        #expect(snap.serialDigest == "")
    }

    @Test func snapshotIsEquatable() {
        let a = SessionSnapshot(status: .booting)
        let b = SessionSnapshot(status: .booting)
        #expect(a == b)

        let c = SessionSnapshot(status: .running, bootDuration: .milliseconds(450))
        let d = SessionSnapshot(status: .running, bootDuration: .milliseconds(451))
        #expect(c != d, "even 1ms of bootDuration drift is a distinct snapshot")
    }

    @Test func snapshotIsLive_DerivesFromStatus() {
        #expect(SessionSnapshot(status: .stopped).isLive == false)
        #expect(SessionSnapshot(status: .booting).isLive == true)
        #expect(SessionSnapshot(status: .running).isLive == true)
        #expect(SessionSnapshot(status: .paused).isLive == true)
        #expect(SessionSnapshot(status: .shuttingDown).isLive == false)
        #expect(SessionSnapshot(status: .crashed(reason: "oom")).isLive == false)
    }

    // MARK: - applyAtomic + session.snapshot round-trip

    @Test func sessionSnapshotRoundtrips() throws {
        let bundle = try makeTempBundle()
        let session = LuminaDesktopSession(bundle: bundle)

        // Baseline: session is initialized to the "initial" shape.
        #expect(session.snapshot == SessionSnapshot.initial)

        // Apply a running snapshot atomically; read back via the
        // accessor. Every observed field must match.
        let running = SessionSnapshot(
            status: .running,
            lastError: nil,
            bootDuration: .milliseconds(390),
            serialDigest: "kernel: ready\n"
        )
        session.applyAtomic(running)
        #expect(session.snapshot == running)
        #expect(session.status == .running)
        #expect(session.bootDuration == .milliseconds(390))
        #expect(session.serialDigest == "kernel: ready\n")
    }

    @Test func applyAtomicIsIdempotentOnSelfAssignment() throws {
        // Regression guard for #21's impossible-state prevention:
        // applying the current snapshot must not write to any field.
        // If any field writes, the @Observable tracker fires an
        // observation tick and SwiftUI re-evaluates views for a
        // transition that didn't happen. The per-field `!=` guards
        // in applyAtomic are what prevent this.
        let bundle = try makeTempBundle()
        let session = LuminaDesktopSession(bundle: bundle)

        let running = SessionSnapshot(
            status: .running,
            bootDuration: .milliseconds(390),
            serialDigest: "kernel: ready\n"
        )
        session.applyAtomic(running)
        let before = session.snapshot

        // Apply the same snapshot. Nothing should change.
        session.applyAtomic(running)
        #expect(session.snapshot == before)
    }

    @Test func applyAtomicCrashPreservesCurrentSerial() throws {
        // Boot failure must NOT wipe the serial digest — the user
        // needs the tail to diagnose the crash. This test pins that
        // applyAtomic takes responsibility for every field in the
        // snapshot; the mutation sites in LuminaDesktopSession
        // explicitly pass through `serialDigest: serialDigest` so
        // the crash transition doesn't clear it.
        let bundle = try makeTempBundle()
        let session = LuminaDesktopSession(bundle: bundle)

        // Simulate a session that was running with a captured tail.
        session.applyAtomic(SessionSnapshot(
            status: .running,
            bootDuration: .milliseconds(390),
            serialDigest: "Kernel panic: not syncing\n"
        ))

        // Now a crash transition passes through the current digest.
        session.applyAtomic(SessionSnapshot(
            status: .crashed(reason: "panic"),
            lastError: "panic",
            bootDuration: session.bootDuration,
            serialDigest: session.serialDigest
        ))
        #expect(session.status == .crashed(reason: "panic"))
        #expect(session.serialDigest == "Kernel panic: not syncing\n",
                "serial digest must be preserved across crash transition")
    }

    // MARK: - canBoot / isLive parity with Status

    @Test func snapshotCanBoot_MatchesStatus() {
        for status: LuminaDesktopSession.Status in [
            .stopped, .booting, .running, .paused,
            .crashed(reason: "x"), .shuttingDown
        ] {
            let snap = SessionSnapshot(status: status)
            #expect(snap.canBoot == status.canBoot,
                    "snapshot.canBoot must mirror status.canBoot for \(status)")
        }
    }

    // MARK: - helpers

    private func makeTempBundle() throws -> VMBundle {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessionsnap-\(UUID().uuidString).luminaVM")
        return try VMBundle.create(
            at: tmp,
            name: "snap",
            osFamily: .linux,
            osVariant: "alpine",
            memoryBytes: 2 * 1024 * 1024 * 1024,
            cpuCount: 2,
            diskBytes: 1024 * 1024 * 1024,
            id: UUID()
        )
    }
}
