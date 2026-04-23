// Sources/LuminaDesktopKit/SessionSnapshot.swift
//
// Value-type bundle of every session-observable field on
// `LuminaDesktopSession`. Introduced in v0.7.1 as the foundation for
// #21's value-type decomposition: an explicit Sendable, Equatable
// shape that:
//
//   1. Makes atomic transitions possible. Boot success writes status
//      and bootDuration together via `applyAtomic(_:)` so SwiftUI
//      observers see one tick with both fields consistent, not two
//      ticks where `.running` briefly pairs with a nil duration.
//   2. Makes previous/next comparisons testable. `Equatable` + the
//      snapshot accessor lets tests assert "this transition is
//      valid" or "no spurious self-assignment fired" without
//      poking at individual properties.
//   3. Makes serialization cheap. A session's full observable state
//      is one struct, encodable for debug dumps or a future
//      `lumina ps --verbose` snapshot view.
//
// Intentionally minimal for v0.7.1: the fields are exactly what
// `LuminaDesktopSession` already exposes. Additional fields the
// issue mentioned (`bootPhases`, `lastBootedAt`) are not mirrored
// onto the session today — adding them here is a follow-up, not
// part of the decomposition groundwork.
//
// The Status type lives on `LuminaDesktopSession` so existing view
// code keeps compiling; we re-export it through the typealias below
// for snapshot callers that want a single import.

import Foundation

/// Every observable field of a `LuminaDesktopSession` bundled into
/// one value type. Populate via `LuminaDesktopSession.snapshot`;
/// apply atomically via `LuminaDesktopSession.applyAtomic(_:)`.
public struct SessionSnapshot: Sendable, Equatable {
    public var status: LuminaDesktopSession.Status
    public var lastError: String?
    public var bootDuration: Duration?
    public var serialDigest: String

    public init(
        status: LuminaDesktopSession.Status = .stopped,
        lastError: String? = nil,
        bootDuration: Duration? = nil,
        serialDigest: String = ""
    ) {
        self.status = status
        self.lastError = lastError
        self.bootDuration = bootDuration
        self.serialDigest = serialDigest
    }

    /// The canonical "nothing has happened yet" snapshot.
    public static let initial = SessionSnapshot()

    /// True when the snapshot represents a VM that's either running,
    /// booting, or paused — the conditions under which the SwiftUI
    /// running-VM window should stay open.
    public var isLive: Bool { status.isLive }

    /// Re-entry guard convenience — see `Status.canBoot`.
    public var canBoot: Bool { status.canBoot }
}
