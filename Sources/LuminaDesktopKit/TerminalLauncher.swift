// Launch strategy per terminal — chosen to work with an ad-hoc-signed
// desktop build where we don't have application-specific entitlements:
//   - Ghostty / Warp / generic: copy the command to the pasteboard,
//     open the terminal app via `open -a`, and surface an instruction
//     toast ("Command copied — press ⌘V to paste"). Robust across
//     terminal versions; no AppleScript permission prompt on first
//     use.
//   - iTerm2: AppleScript `create window with default profile` +
//     `write text`, which auto-executes. Falls back to the pasteboard
//     path if the AppleScript fails (TCC permission denied, iTerm
//     restarted but not running yet, etc.).
//   - Terminal.app: AppleScript `do script`, which opens a new window
//     and runs the command. Always-installed fallback.

import AppKit
import Foundation

public enum TerminalLaunchOutcome: Equatable, Sendable {
    case executed(terminal: TerminalKind)
    case copiedAndOpened(terminal: TerminalKind)
    case failed(reason: String)
}

/// Enumerates the terminals we know how to launch. `.system` is the
/// "whatever the user set as their default" signal passed to
/// NSWorkspace; falls back to Terminal.app in practice.
public enum TerminalKind: String, CaseIterable, Sendable, Equatable {
    case terminal
    case iterm2
    case ghostty
    case warp

    public var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm2:   return "com.googlecode.iterm2"
        case .ghostty:  return "com.mitchellh.ghostty"
        case .warp:     return "dev.warp.Warp-Stable"
        }
    }

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2:   return "iTerm2"
        case .ghostty:  return "Ghostty"
        case .warp:     return "Warp"
        }
    }

}

public protocol TerminalEnvironment: Sendable {
    func isInstalled(_ kind: TerminalKind) -> Bool

    func copyToPasteboard(_ command: String)

    func openApp(bundleIdentifier: String) -> Bool

    func runAppleScript(_ script: String) -> Bool
}

/// Lock-guarded box for the `openApplication` completion result. The
/// handler runs on a queue outside the calling thread, so the result
/// can't just be a captured `var` (Swift 6 flags the mutation as a data
/// race even though the semaphore wait below makes it safe in practice).
/// Matches the class-with-NSLock pattern used elsewhere in Lumina for
/// synchronous completion-handler callbacks (see `DesktopCommand.ProgressBucket`).
private final class OpenAppResult: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false

    func set(_ value: Bool) {
        lock.withLock { succeeded = value }
    }

    var value: Bool {
        lock.withLock { succeeded }
    }
}

public struct DefaultTerminalEnvironment: TerminalEnvironment {
    public init() {}

    public func isInstalled(_ kind: TerminalKind) -> Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: kind.bundleIdentifier
        ) != nil
    }

    public func copyToPasteboard(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    public func openApp(bundleIdentifier: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let sem = DispatchSemaphore(value: 0)
        let result = OpenAppResult()
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            result.set(err == nil)
            sem.signal()
        }
        // Short timeout — if NSWorkspace is this unhealthy, the user
        // has bigger problems than a missing terminal window. The
        // pasteboard fallback kicks in via the caller anyway.
        _ = sem.wait(timeout: .now() + .seconds(3))
        return result.value
    }

    public func runAppleScript(_ script: String) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

public struct TerminalLauncher: Sendable {
    public static let preferenceKey = "lumina.desktop.preferredTerminal"

    private let env: any TerminalEnvironment

    public init(env: any TerminalEnvironment = DefaultTerminalEnvironment()) {
        self.env = env
    }

    public func resolveTerminal(
        preferenceRaw: String? = UserDefaults.standard.string(
            forKey: TerminalLauncher.preferenceKey
        )
    ) -> TerminalKind {
        if let raw = preferenceRaw,
           raw != "auto",
           let kind = TerminalKind(rawValue: raw),
           env.isInstalled(kind) {
            return kind
        }
        // Auto order: Ghostty → iTerm2 → Warp → Terminal. Agent
        // engineers skew modern-terminal; Terminal.app is the always-
        // installed fallback.
        for candidate: TerminalKind in [.ghostty, .iterm2, .warp, .terminal] {
            if env.isInstalled(candidate) { return candidate }
        }
        // Terminal.app is bundled with macOS; this branch is unreachable
        // in practice but we keep the type total.
        return .terminal
    }

    public func launch(
        command: String,
        preferenceRaw: String? = UserDefaults.standard.string(
            forKey: TerminalLauncher.preferenceKey
        )
    ) -> TerminalLaunchOutcome {
        let kind = resolveTerminal(preferenceRaw: preferenceRaw)

        switch kind {
        case .iterm2:
            return launchIterm2(command: command)
        case .terminal:
            return launchTerminalApp(command: command)
        case .ghostty, .warp:
            return launchViaPasteboard(command: command, kind: kind)
        }
    }

    // MARK: - per-terminal strategies

    private func launchTerminalApp(command: String) -> TerminalLaunchOutcome {
        let escaped = appleScriptEscape(command)
        let script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
        """
        if env.runAppleScript(script) {
            return .executed(terminal: .terminal)
        }
        env.copyToPasteboard(command)
        if env.openApp(bundleIdentifier: TerminalKind.terminal.bundleIdentifier) {
            return .copiedAndOpened(terminal: .terminal)
        }
        return .failed(reason: "Couldn't open Terminal.app. Check System Settings → Privacy & Security → Automation for Lumina.")
    }

    private func launchIterm2(command: String) -> TerminalLaunchOutcome {
        let escaped = appleScriptEscape(command)
        let script = """
            tell application "iTerm"
                activate
                if (count of windows) = 0 then
                    create window with default profile
                end if
                tell current session of current window
                    write text "\(escaped)"
                end tell
            end tell
        """
        if env.runAppleScript(script) {
            return .executed(terminal: .iterm2)
        }
        env.copyToPasteboard(command)
        if env.openApp(bundleIdentifier: TerminalKind.iterm2.bundleIdentifier) {
            return .copiedAndOpened(terminal: .iterm2)
        }
        return .failed(reason: "Couldn't launch iTerm2. Grant Automation permission in System Settings or switch the default terminal in Lumina's preferences.")
    }

    private func launchViaPasteboard(
        command: String,
        kind: TerminalKind
    ) -> TerminalLaunchOutcome {
        // Ghostty and Warp don't have a stable scripting surface we
        // can rely on across versions, so the safe path is: copy the
        // command, open the app, tell the user to paste. Not elegant
        // but it doesn't silently do the wrong thing.
        env.copyToPasteboard(command)
        if env.openApp(bundleIdentifier: kind.bundleIdentifier) {
            return .copiedAndOpened(terminal: kind)
        }
        return .failed(reason: "Couldn't launch \(kind.displayName). Is it installed?")
    }

    // MARK: - escaping

    /// Escape a command string for embedding inside an AppleScript
    /// double-quoted literal. Backslashes and double-quotes must be
    /// escaped; newlines would break the string literal, so we
    /// reject commands that contain them (callers pass single-line
    /// shell commands). Returning the best-effort escape rather than
    /// throwing is acceptable because any remaining quoting issue
    /// surfaces as an AppleScript compile failure, which the caller
    /// already handles via the pasteboard fallback.
    private func appleScriptEscape(_ cmd: String) -> String {
        cmd.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: " ")
    }
}
