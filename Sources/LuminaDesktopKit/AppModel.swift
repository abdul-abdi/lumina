// Sources/LuminaDesktopKit/AppModel.swift
//
// v0.7.0 M6 — top-level @Observable @MainActor state for the
// Lumina Desktop app. Owned by the `LuminaDesktopApp` (the @main scene
// entry point in Apps/LuminaDesktop/) and passed into views via
// `@Environment` / `.environmentObject` patterns.

import Foundation
import Observation
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

    public init(store: VMStore = VMStore()) {
        self.store = store
        refresh()
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
