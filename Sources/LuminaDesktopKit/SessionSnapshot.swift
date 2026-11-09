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
// The Status type lives on `LuminaDesktopSession` so existing view
// code keeps compiling; we re-export it through the typealias below
// for snapshot callers that want a single import.

import Foundation
import Lumina

public struct SessionSnapshot: Sendable, Equatable {
    public var status: LuminaDesktopSession.Status
    public var lastError: String?
    public var bootDuration: Duration?
    public var serialDigest: String
    /// Per-phase boot timing, captured from the VM actor after boot
    /// completes. `BootPhases()` for sessions that have never booted
    /// or are mid-boot — use `bootPhases.isValid` to gate UI rendering
    /// so the waterfall doesn't draw a row of "0 ms" phases.
    public var bootPhases: BootPhases

    public init(
        status: LuminaDesktopSession.Status = .stopped,
        lastError: String? = nil,
        bootDuration: Duration? = nil,
        serialDigest: String = "",
        bootPhases: BootPhases = BootPhases()
    ) {
        self.status = status
        self.lastError = lastError
        self.bootDuration = bootDuration
        self.serialDigest = serialDigest
        self.bootPhases = bootPhases
    }

    public static let initial = SessionSnapshot()

    public var isLive: Bool { status.isLive }

    public var canBoot: Bool { status.canBoot }
}
