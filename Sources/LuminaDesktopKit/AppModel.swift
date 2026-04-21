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

    public func deleteBundle(_ bundle: VMBundle) {
        // Stop any running session first.
        if let session = sessions[bundle.manifest.id], session.status.isLive {
            Task { await session.shutdown() }
        }
        sessions.removeValue(forKey: bundle.manifest.id)
        if !store.moveToTrash(bundle) {
            pendingError = "Couldn't move \(bundle.manifest.name) to Trash."
        }
        refresh()
    }
}
