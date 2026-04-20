// Apps/LuminaDesktop/LuminaDesktop/LuminaDesktopApp.swift
//
// v0.7.0 M6 — @main entry for the Lumina Desktop app.
// All UI lives in the LuminaDesktopKit SPM target; this file is just the
// scene + window orchestration.

import SwiftUI
import LuminaDesktopKit
import LuminaBootable

@main
struct LuminaDesktopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Lumina") {
            LibraryView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New VM") {
                    NotificationCenter.default.post(name: Notification.Name("LuminaShowWizard"), object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        WindowGroup(id: "vm-window", for: UUID.self) { $vmID in
            if let id = vmID, let bundle = model.bundles.first(where: { $0.manifest.id == id }) {
                RunningVMView(session: model.session(for: bundle))
                    .frame(minWidth: 1024, minHeight: 600)
            } else {
                Text("VM not found").padding()
            }
        }

        Settings {
            PreferencesView(model: model)
        }
    }
}

@MainActor
struct PreferencesView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            libraryTab.tabItem { Label("Library", systemImage: "folder") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }

    private var generalTab: some View {
        Form {
            Picker("Sort order", selection: $model.sortOrder) {
                ForEach(AppModel.SortOrder.allCases, id: \.rawValue) { o in
                    Text(o.rawValue).tag(o)
                }
            }
            Picker("Group by", selection: $model.groupBy) {
                ForEach(AppModel.GroupBy.allCases, id: \.rawValue) { g in
                    Text(g.rawValue).tag(g)
                }
            }
        }
        .padding(20)
    }

    private var libraryTab: some View {
        Form {
            HStack {
                Text("VM library")
                Spacer()
                Text(model.store.rootURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Shared with the `lumina` CLI. Edit Preferences in v0.8 to relocate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(LinearGradient(
                    colors: [.purple, .blue, .pink, .orange],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text("Lumina Desktop")
                .font(.title3.weight(.semibold))
            Text("v0.7.0")
                .foregroundStyle(.secondary)
            Text("Native Apple Workload Runtime for Agents")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
