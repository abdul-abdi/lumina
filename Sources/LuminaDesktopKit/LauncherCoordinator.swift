// Sources/LuminaDesktopKit/LauncherCoordinator.swift
//
// Intra-process UI-event bus for the Desktop app. Replaces what used
// to be posted through `NotificationCenter` (LuminaLauncherOpenWizard,
// LuminaShowLauncher). `@Observable` state with explicit request
// stamps — SwiftUI observes mutations, and we stay off the dynamic
// Notification bus for events that only ever travel inside this app.
//
// System notifications (NSWindow fullscreen, DistributedNotificationCenter
// appearance changes) keep using `NotificationCenter` because that is
// the API AppKit publishes them on.
//
// Injected explicitly via constructor parameters (same pattern as
// `AppModel` and `AppUIState`). Not an environment value, because an
// `EnvironmentKey`'s `defaultValue` must be nonisolated-constructible
// and this type is `@MainActor`.

import SwiftUI

@MainActor
@Observable
public final class LauncherCoordinator {
    /// Set to a tile id when the New-VM wizard should open preselecting that OS.
    /// Observers reset this to `nil` after reacting.
    public var pendingWizardTile: String? = nil

    /// Bumped each time the ⌘K launcher should be shown. Observers compare
    /// against their last-seen value — the UUID identity is the signal, the
    /// value itself is opaque. Using a stamp rather than a `Bool` avoids
    /// re-entrancy when the view sets the sheet binding back to `false`.
    public var launcherRequestStamp: UUID? = nil

    public init() {}

    public func openWizard(preselecting tileID: String) {
        pendingWizardTile = tileID
    }

    public func showLauncher() {
        launcherRequestStamp = UUID()
    }
}
