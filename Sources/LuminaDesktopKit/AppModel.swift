// Sources/LuminaDesktopKit/AppModel.swift
//
// v0.7.0 M6 — top-level @Observable @MainActor state for the
// Lumina Desktop app. Owned by the `LuminaDesktopApp` (the @main scene
// entry point in Apps/LuminaDesktop/) and passed into views via
// `@Environment` / `.environmentObject` patterns.

import Foundation
import Observation
import Darwin
import LuminaBootable

@MainActor
@Observable
public final class AppModel {
    public var bundles: [VMBundle] = []
    public var sessions: [UUID: LuminaDesktopSession] = [:]
    public var sortOrder: SortOrder = .lastUsed
    public var groupBy: GroupBy = .none
    public var search: String = ""
    public var selection: UUID?
    public var pendingError: String?

    public let store: VMStore

    // Single owner for per-bundle VMLiveStats timers. Keyed by
    // `bundle.manifest.id` so grid ↔ list layout swaps, window reopens,
    // and redundant view bodies all observe the SAME stats instance
    // (one timer per bundle) instead of spinning a fresh `stat(2)`
    // loop per view. Issue #11.
    private var liveStatsByBundle: [UUID: VMLiveStats] = [:]

    // Reaper task that retires idle sessions periodically. Scans every
    // 60s and removes any `.stopped` / `.crashed` session whose status
    // has been idle for >300s. For daemon-mode uptime (app running for
    // days), this keeps `sessions` from growing monotonically with
    // mostly-dead entries. Issue #13.
    private var reaperTask: Task<Void, Never>?
    private var lastInactiveAt: [UUID: Date] = [:]
    private let reaperIdleThreshold: TimeInterval = 300   // 5 min
    private let reaperScanInterval: TimeInterval = 60    // 1 min

    // FS watcher for ~/.lumina/desktop-vms/ — VMs created via CLI or other
    // processes show up in the library within ~100ms of landing on disk.
    // No poll, no "refresh" button. The file system IS the model.
    //
    // Both properties are MainActor-isolated (the enclosing class is
    // `@MainActor`). The watcher's event handler fires on `.main`, and
    // the cancel handler captures the raw fd by value so it doesn't need
    // to touch `self`.
    private var fsWatcher: DispatchSourceFileSystemObject?
    private var fsWatcherFd: Int32 = -1

    public init(store: VMStore = VMStore()) {
        self.store = store
        refresh()
        installFilesystemWatcher()
        startSessionReaper()
    }

    private func installFilesystemWatcher() {
        let path = store.rootURL.path
        // Ensure the directory exists so we can open it.
        try? FileManager.default.createDirectory(
            at: store.rootURL, withIntermediateDirectories: true
        )
        let fd = path.withCString { Darwin.open($0, O_EVTONLY) }
        guard fd >= 0 else { return }
        fsWatcherFd = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            // Coalesce bursts — if 3 files are created in rapid succession,
            // we still only do one scan per 80ms.
            guard let self else { return }
            self.scheduleCoalescedRefresh()
        }
        // Capture the fd by value so the handler doesn't need `self`.
        // After cancel there's nothing left to mutate on the model — the
        // source itself is torn down by Dispatch and the fd is closed here.
        let capturedFd = fd
        src.setCancelHandler {
            if capturedFd >= 0 { Darwin.close(capturedFd) }
        }
        src.resume()
        fsWatcher = src
    }

    private var refreshTask: Task<Void, Never>?
    private func scheduleCoalescedRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self.refresh()
        }
    }

    public enum SortOrder: String, CaseIterable, Sendable {
        case lastUsed = "Last used"
        case created = "Created"
        case name = "Name"
        case osFamily = "OS"
    }

    public enum GroupBy: String, CaseIterable, Sendable {
        case none = "None"
        case status = "Status"
        case osFamily = "OS"
    }

    public func refresh() {
        bundles = store.loadBundles()
    }

    public var filteredBundles: [VMBundle] {
        let filtered: [VMBundle]
        if search.isEmpty {
            filtered = bundles
        } else {
            let q = search.lowercased()
            filtered = bundles.filter {
                $0.manifest.name.lowercased().contains(q) ||
                $0.manifest.osVariant.lowercased().contains(q)
            }
        }
        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .lastUsed:
                return (lhs.manifest.lastBootedAt ?? lhs.manifest.createdAt)
                    > (rhs.manifest.lastBootedAt ?? rhs.manifest.createdAt)
            case .created:
                return lhs.manifest.createdAt > rhs.manifest.createdAt
            case .name:
                return lhs.manifest.name.localizedCompare(rhs.manifest.name) == .orderedAscending
            case .osFamily:
                return lhs.manifest.osVariant.localizedCompare(rhs.manifest.osVariant) == .orderedAscending
            }
        }
    }

    /// Get-or-create a session for a bundle. Sessions are kept in the
    /// dictionary so the running-VM window doesn't lose state when the
    /// user navigates away and back.
    public func session(for bundle: VMBundle) -> LuminaDesktopSession {
        if let existing = sessions[bundle.manifest.id] { return existing }
        let s = LuminaDesktopSession(bundle: bundle)
        sessions[bundle.manifest.id] = s
        return s
    }

    /// Get-or-create the live-stats timer for a bundle. Single source of
    /// truth — the grid card and the list row of the same VM share one
    /// instance, so a layout swap doesn't spawn a duplicate 2-second
    /// `stat(2)` poll. Issue #11.
    public func liveStats(for bundle: VMBundle) -> VMLiveStats {
        if let existing = liveStatsByBundle[bundle.manifest.id] { return existing }
        let s = VMLiveStats(bundle: bundle)
        liveStatsByBundle[bundle.manifest.id] = s
        return s
    }

    /// Stop and retire the live-stats timer for a bundle. Called from
    /// `deleteBundle` and from the session reaper when a session gets
    /// evicted. Safe to call with no live entry.
    public func retireLiveStats(for id: UUID) {
        liveStatsByBundle.removeValue(forKey: id)?.stop()
    }

    /// Start the periodic reaper. On each tick it evicts any session
    /// whose status has been `.stopped` or `.crashed` for more than
    /// `reaperIdleThreshold` seconds, along with its live-stats entry.
    /// Sessions with live status (`.booting`/`.running`/`.paused`/
    /// `.shuttingDown`) are never touched. Idempotent: re-entry returns
    /// immediately if the task is already running. Issue #13.
    private func startSessionReaper() {
        guard reaperTask == nil else { return }
        reaperTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.reaperScanInterval ?? 60))
                self?.reapIdleSessions()
            }
        }
    }

    /// Run one reaper pass. Exposed for tests; called by the periodic
    /// task in production.
    public func reapIdleSessions(now: Date = Date()) {
        for (id, session) in sessions {
            if session.status.isLive {
                lastInactiveAt.removeValue(forKey: id)
                continue
            }
            let markedAt = lastInactiveAt[id] ?? now
            if markedAt == now {
                // First observation of this session as inactive — stamp it.
                lastInactiveAt[id] = now
                continue
            }
            if now.timeIntervalSince(markedAt) >= reaperIdleThreshold {
                sessions.removeValue(forKey: id)
                retireLiveStats(for: id)
                lastInactiveAt.removeValue(forKey: id)
            }
        }
    }

    /// Number of sessions currently in a live status. Reading any child
    /// session's `status` inside this computed property means `@Observable`
    /// tracks the transitive reads, so the value re-evaluates whenever any
    /// individual session flips — not just when `sessions` mutates. Views
    /// bind to this instead of re-implementing the reduce-in-body pattern.
    public var runningCount: Int {
        sessions.values.reduce(into: 0) { count, session in
            if session.status.isLive { count += 1 }
        }
    }

    public func deleteBundle(_ bundle: VMBundle) {
        // Stop any running session first.
        if let session = sessions[bundle.manifest.id], session.status.isLive {
            Task { await session.shutdown() }
        }
        sessions.removeValue(forKey: bundle.manifest.id)
        retireLiveStats(for: bundle.manifest.id)
        if !store.moveToTrash(bundle) {
            pendingError = "Couldn't move \(bundle.manifest.name) to Trash."
        }
        refresh()
    }
}
