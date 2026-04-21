// Sources/LuminaDesktopKit/LibraryEmptyStates.swift
//
// Empty-library hero and filter-empty placeholder. Extracted from
// LibraryView.swift so the library entry-point stays focused on the
// NavigationSplitView composition.

import SwiftUI

@MainActor
public struct EmptyStateView: View {
    let onChoose: (String?) -> Void   // nil = open blank wizard, else pre-pick tile id

    public init(onChoose: @escaping (String?) -> Void) {
        self.onChoose = onChoose
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                BrandMarkLarge()
                    .frame(width: 80, height: 80)
                VStack(spacing: 8) {
                    Text("subprocess.run()")
                        .foregroundStyle(LuminaTheme.accent)
                        .font(.system(size: 36, weight: .medium, design: .monospaced))
                        .tracking(-0.5)

                    HStack(spacing: 10) {
                        Text("for")
                            .font(.system(size: 36, weight: .medium, design: .monospaced))
                            .foregroundStyle(LuminaTheme.ink)
                            .tracking(-0.5)
                        Text("virtual machines.")
                            .font(.system(.title, design: .serif).italic())
                            .foregroundStyle(LuminaTheme.inkDim)
                    }
                }
                Text("Spin up Ubuntu, Kali, Windows 11 ARM, or macOS — \nand throw it away when you're done.")
                    .font(.system(size: 14))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                HStack(spacing: 10) {
                    PrimaryAction(label: "Try Ubuntu", systemImage: "circle.hexagongrid.fill", isPrimary: true) {
                        onChoose("ubuntu-24.04")
                    }
                    PrimaryAction(label: "Install Windows 11", systemImage: "macwindow") {
                        onChoose("windows-11-arm")
                    }
                    PrimaryAction(label: "Install macOS", systemImage: "apple.logo") {
                        onChoose("macos-latest")
                    }
                    PrimaryAction(label: "Use my own…", systemImage: "doc.badge.plus") {
                        onChoose("byo-file")
                    }
                }
                .padding(.top, 8)
            }
            Spacer()
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.doc")
                    .foregroundStyle(LuminaTheme.inkMute)
                Text("Drop an ISO or IPSW anywhere on this window")
                    .font(.system(size: 12))
                    .foregroundStyle(LuminaTheme.inkMute)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
public struct EmptyFilterView: View {
    let section: SidebarSection

    public init(section: SidebarSection) {
        self.section = section
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(LuminaTheme.inkMute)
            Text("No VMs in \(section.rawValue)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LuminaTheme.ink)
            Text("Create one from the toolbar.")
                .font(.system(size: 12))
                .foregroundStyle(LuminaTheme.inkDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
public struct BrandMarkLarge: View {
    public init() {}
    public var body: some View {
        ZStack {
            // back square (cream)
            RoundedRectangle(cornerRadius: 8)
                .stroke(LuminaTheme.ink.opacity(0.4), lineWidth: 2)
                .frame(width: 56, height: 56)
                .offset(x: 12, y: 12)
            // front square (amber, with subtle glow)
            RoundedRectangle(cornerRadius: 8)
                .stroke(LuminaTheme.accent, lineWidth: 2)
                .frame(width: 56, height: 56)
                .shadow(color: LuminaTheme.accent.opacity(0.4), radius: 8)
        }
    }
}

@MainActor
public struct PrimaryAction: View {
    let label: String
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(label: String, systemImage: String, isPrimary: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.isPrimary = isPrimary
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
            }
            .foregroundStyle(isPrimary ? Color.black : (hovering ? LuminaTheme.accent : LuminaTheme.ink))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPrimary ? LuminaTheme.accent : LuminaTheme.bg1.opacity(hovering ? 0.9 : 0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isPrimary ? Color.clear : (hovering ? LuminaTheme.accent.opacity(0.5) : LuminaTheme.rule2),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
