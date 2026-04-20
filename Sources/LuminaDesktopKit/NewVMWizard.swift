// Sources/LuminaDesktopKit/NewVMWizard.swift
//
// v0.7.0 M6 — 4-step wizard: choose OS → variant → resources → review.

import SwiftUI
import LuminaBootable

@MainActor
public struct NewVMWizard: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    @State private var step: Step = .chooseOS
    @State private var selectedTile: OSWizardTile?
    @State private var byoFile: URL?
    @State private var nameOverride: String = ""
    @State private var memoryGB: Double = 4
    @State private var cpus: Int = 2
    @State private var diskGB: Double = 32

    public init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        self._isPresented = isPresented
    }

    enum Step: Int, CaseIterable { case chooseOS = 0, variant, resources, review }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LuminaTheme.rule).frame(height: 1)
            Group {
                switch step {
                case .chooseOS: chooseOSStep
                case .variant: variantStep
                case .resources: resourcesStep
                case .review: reviewStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LuminaTheme.bg)
            .transition(.opacity.combined(with: .move(edge: .leading)))
            Rectangle().fill(LuminaTheme.rule).frame(height: 1)
            footer
        }
        .frame(width: 760, height: 560)
        .background(LuminaTheme.bg)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.18), value: step)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("§ \(String(format: "%02d", step.rawValue + 1))")
                .font(LuminaTheme.label)
                .tracking(1.5)
                .foregroundStyle(LuminaTheme.accent)
            Text(stepTitle)
                .font(LuminaTheme.title)
                .foregroundStyle(LuminaTheme.ink)
            HStack(spacing: 4) {
                Text("of 4")
                    .font(LuminaTheme.label)
                    .tracking(1.5)
                    .foregroundStyle(LuminaTheme.inkMute)
                    .textCase(.uppercase)
            }
            Spacer()
            stepIndicator
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(LuminaTheme.bg2)
    }

    private var stepTitle: String {
        switch step {
        case .chooseOS: "CHOOSE AN OS"
        case .variant: "PICK A VARIANT"
        case .resources: "RESOURCES"
        case .review: "REVIEW + CREATE"
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(i <= step.rawValue ? LuminaTheme.accent : LuminaTheme.rule2)
                    .frame(width: 24, height: 2)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: { isPresented = false }) {
                Text("[ ESC ] CANCEL")
                    .font(LuminaTheme.label)
                    .tracking(1.5)
                    .foregroundStyle(LuminaTheme.inkMute)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            if step != .chooseOS {
                Button(action: { back() }) {
                    Text("← BACK")
                        .font(LuminaTheme.label)
                        .tracking(1.5)
                        .foregroundStyle(LuminaTheme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            LuminaPrimaryButton(label: step == .review ? "CREATE VM →" : "NEXT →") {
                next()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .opacity(canAdvance ? 1 : 0.4)
            .disabled(!canAdvance)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(LuminaTheme.bg2)
    }

    private var chooseOSStep: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                ForEach(OSCatalog.allTiles) { tile in
                    OSTileButton(
                        tile: tile,
                        isSelected: selectedTile?.id == tile.id,
                        onTap: { selectedTile = tile }
                    )
                }
            }
            .padding(20)
        }
    }

    private var variantStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let tile = selectedTile {
                Text(tile.displayName)
                    .font(.title3.weight(.semibold))
                Text(tile.description)
                    .foregroundStyle(.secondary)

                switch tile.acquisition {
                case .catalogISO(let entry):
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Installer ISO")
                                .font(.headline)
                            Text(entry.isoURL.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("Approx. \(formatGB(entry.isoSizeBytes)) — downloaded on first create.")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                case .microsoftAccountDownload:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Microsoft requires a Microsoft Account to download the ISO.")
                                .font(.headline)
                            Text("Lumina opens the download page in your browser. After downloading, drop the ISO here.")
                                .foregroundStyle(.secondary)
                            Button("Open Microsoft Download Page") {
                                NSWorkspace.shared.open(URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!)
                            }
                            .padding(.top, 4)
                            isoPicker
                        }
                        .padding(8)
                    }
                case .appleIPSW:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lumina downloads the macOS IPSW directly from Apple (~15 GB).")
                                .font(.headline)
                            Text("By continuing you accept Apple's licensing terms. You can also pick an IPSW file you already have.")
                                .foregroundStyle(.secondary)
                            ipswPicker
                        }
                        .padding(8)
                    }
                case .userProvided:
                    isoPicker
                }
            }
            Spacer()
        }
        .padding(20)
    }

    private var resourcesStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            sliderRow(label: "Memory", value: $memoryGB, range: 1...32, step: 1, suffix: "GB")
            sliderRow(label: "CPU cores", valueInt: $cpus, range: 1...8)
            sliderRow(label: "Disk size", value: $diskGB, range: 4...256, step: 4, suffix: "GB")
            Text("Defaults match the OS you picked. Tweak if you know what you need.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .onAppear { applyOSDefaults() }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Name")
                    .frame(width: 80, alignment: .leading)
                TextField("VM name", text: $nameOverride)
            }
            row("OS", selectedTile?.displayName ?? "")
            row("Memory", "\(Int(memoryGB)) GB")
            row("CPUs", "\(cpus)")
            row("Disk", "\(Int(diskGB)) GB")
            Spacer()
        }
        .padding(20)
        .onAppear {
            if nameOverride.isEmpty, let tile = selectedTile {
                nameOverride = tile.displayName
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            Text(value)
            Spacer()
        }
        .font(.body)
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func sliderRow(label: String, valueInt: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text("\(valueInt.wrappedValue)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            let doubleBinding = Binding<Double>(
                get: { Double(valueInt.wrappedValue) },
                set: { valueInt.wrappedValue = Int($0) }
            )
            Slider(value: doubleBinding, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
        }
    }

    private var isoPicker: some View {
        HStack {
            if let f = byoFile {
                Text(f.lastPathComponent).foregroundStyle(.secondary)
            } else {
                Text("No file selected").foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.allowedContentTypes = []
                panel.title = "Pick an ISO file"
                if panel.runModal() == .OK { byoFile = panel.url }
            }
        }
    }

    private var ipswPicker: some View {
        HStack {
            if let f = byoFile {
                Text(f.lastPathComponent).foregroundStyle(.secondary)
            } else {
                Text("No file selected").foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Choose IPSW…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.title = "Pick an IPSW file"
                if panel.runModal() == .OK { byoFile = panel.url }
            }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .chooseOS: selectedTile != nil
        case .variant: true   // catalog tiles auto-advance; BYO must have file but we let it pass for v0.7
        case .resources, .review: true
        }
    }

    private func next() {
        switch step {
        case .chooseOS: step = .variant
        case .variant: step = .resources
        case .resources: step = .review
        case .review: createAndDismiss()
        }
    }

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    private func applyOSDefaults() {
        guard let tile = selectedTile else { return }
        switch tile.acquisition {
        case .catalogISO(let entry):
            memoryGB = Double(entry.recommendedMemoryBytes / (1024 * 1024 * 1024))
            cpus = entry.recommendedCPUs
            diskGB = Double(entry.recommendedDiskBytes / (1024 * 1024 * 1024))
        case .microsoftAccountDownload:
            memoryGB = 8; cpus = 4; diskGB = 64
        case .appleIPSW:
            memoryGB = 8; cpus = 4; diskGB = 64
        case .userProvided:
            break
        }
    }

    private func createAndDismiss() {
        guard let tile = selectedTile else { return }
        let osFamily = tile.family
        let osVariant = tile.id
        let memBytes = UInt64(memoryGB) * 1024 * 1024 * 1024
        let diskBytes = UInt64(diskGB) * 1024 * 1024 * 1024

        let id = UUID()
        let rootURL = model.store.rootURL.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: model.store.rootURL, withIntermediateDirectories: true)

        do {
            let bundle = try VMBundle.create(
                at: rootURL,
                name: nameOverride.isEmpty ? tile.displayName : nameOverride,
                osFamily: osFamily,
                osVariant: osVariant,
                memoryBytes: memBytes,
                cpuCount: cpus,
                diskBytes: diskBytes,
                id: id
            )
            try DiskImageAllocator.allocate(at: bundle.primaryDiskURL, logicalSize: diskBytes)
            // Stage BYO file if provided.
            if let f = byoFile {
                let sidecar = bundle.rootURL.appendingPathComponent("pending-iso.path")
                try? Data(f.path.utf8).write(to: sidecar, options: .atomic)
            }
        } catch {
            model.pendingError = "Couldn't create VM: \(error)"
        }
        model.refresh()
        isPresented = false
    }

    private func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

@MainActor
struct OSTileButton: View {
    let tile: OSWizardTile
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: tile.glyph)
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(isSelected ? LuminaTheme.accent : LuminaTheme.ink)
                    Spacer()
                    if isSelected {
                        Text("●")
                            .font(LuminaTheme.label)
                            .foregroundStyle(LuminaTheme.accent)
                    }
                }
                Text(tile.displayName)
                    .font(LuminaTheme.headline)
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(1)
                Text(tile.description)
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkDim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let constraint = tile.constraint {
                    Text(constraint.uppercased())
                        .font(LuminaTheme.label)
                        .tracking(1.5)
                        .foregroundStyle(LuminaTheme.inkMute)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                isSelected ? LuminaTheme.accent.opacity(0.08) :
                hovering ? LuminaTheme.bg1 : Color.clear
            )
            .overlay(
                Rectangle()
                    .stroke(isSelected ? LuminaTheme.accent : (hovering ? LuminaTheme.accent.opacity(0.5) : LuminaTheme.rule2),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}
