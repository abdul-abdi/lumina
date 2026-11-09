import AppKit
@preconcurrency import Virtualization

@MainActor
enum DesktopWindow {
    private static var windows: [NSWindow] = []

    static func show(_ machine: VZVirtualMachine?, title: String) {
        guard let machine else { return }
        let app = NSApplication.shared
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        if windows.isEmpty {
            app.setActivationPolicy(.regular)
            DispatchQueue.main.async { app.run() }
        }
        windows.append(window)
    }
}
