// Tests/LuminaDesktopKitTests/TerminalLauncherTests.swift
//
// Unit tests for TerminalLauncher — proves detection order, preference
// override, and the executed / copied / failed outcomes wire to the
// right code paths without actually launching a terminal.

import Foundation
import Testing
@testable import LuminaDesktopKit

/// Fake environment that records every call and returns scripted
/// results. Serializes through a reference-semantics class so test
/// assertions can read recorded state after `launch` returns.
final class RecordingEnvironment: TerminalEnvironment, @unchecked Sendable {
    var installed: Set<TerminalKind> = []
    var appleScriptResult = true
    var openAppResult = true

    var pasteboardCopies: [String] = []
    var openAppCalls: [String] = []
    var appleScriptCalls: [String] = []

    func isInstalled(_ kind: TerminalKind) -> Bool { installed.contains(kind) }
    func copyToPasteboard(_ command: String) { pasteboardCopies.append(command) }
    func openApp(bundleIdentifier: String) -> Bool {
        openAppCalls.append(bundleIdentifier)
        return openAppResult
    }
    func runAppleScript(_ script: String) -> Bool {
        appleScriptCalls.append(script)
        return appleScriptResult
    }
}

@Suite struct TerminalLauncherTests {

    // MARK: - resolveTerminal

    @Test func explicitPreferenceWinsWhenInstalled() {
        let env = RecordingEnvironment()
        env.installed = [.ghostty, .iterm2, .terminal]
        let launcher = TerminalLauncher(env: env)
        #expect(launcher.resolveTerminal(preferenceRaw: "iterm2") == .iterm2)
    }

    @Test func explicitPreferenceFallsBackWhenNotInstalled() {
        let env = RecordingEnvironment()
        env.installed = [.terminal] // user asked for iterm2, doesn't have it
        let launcher = TerminalLauncher(env: env)
        // Falls through to auto-detect. Only Terminal.app is installed.
        #expect(launcher.resolveTerminal(preferenceRaw: "iterm2") == .terminal)
    }

    @Test func autoPrefersGhosttyOverIterm2() {
        let env = RecordingEnvironment()
        env.installed = [.ghostty, .iterm2, .warp, .terminal]
        let launcher = TerminalLauncher(env: env)
        #expect(launcher.resolveTerminal(preferenceRaw: "auto") == .ghostty)
    }

    @Test func autoFallsBackToIterm2WithoutGhostty() {
        let env = RecordingEnvironment()
        env.installed = [.iterm2, .terminal]
        let launcher = TerminalLauncher(env: env)
        #expect(launcher.resolveTerminal(preferenceRaw: "auto") == .iterm2)
    }

    @Test func autoFallsBackToTerminalWhenOnlyAppleInstalled() {
        let env = RecordingEnvironment()
        env.installed = [.terminal]
        let launcher = TerminalLauncher(env: env)
        #expect(launcher.resolveTerminal(preferenceRaw: "auto") == .terminal)
    }

    @Test func nilPreferenceIsEquivalentToAuto() {
        let env = RecordingEnvironment()
        env.installed = [.warp, .terminal]
        let launcher = TerminalLauncher(env: env)
        #expect(launcher.resolveTerminal(preferenceRaw: nil) == .warp)
    }

    // MARK: - launch outcomes

    @Test func iterm2Launch_UsesAppleScriptOnSuccess() {
        let env = RecordingEnvironment()
        env.installed = [.iterm2]
        env.appleScriptResult = true
        let launcher = TerminalLauncher(env: env)

        let outcome = launcher.launch(command: "lumina session start --image mypy", preferenceRaw: "iterm2")
        #expect(outcome == .executed(terminal: .iterm2))
        #expect(env.appleScriptCalls.count == 1)
        #expect(env.appleScriptCalls.first?.contains("iTerm") == true)
        #expect(env.appleScriptCalls.first?.contains("lumina session start --image mypy") == true)
        #expect(env.pasteboardCopies.isEmpty)
    }

    @Test func iterm2Launch_FallsBackToPasteboardWhenAppleScriptFails() {
        let env = RecordingEnvironment()
        env.installed = [.iterm2]
        env.appleScriptResult = false
        env.openAppResult = true
        let launcher = TerminalLauncher(env: env)

        let outcome = launcher.launch(command: "lumina session start --image mypy", preferenceRaw: "iterm2")
        #expect(outcome == .copiedAndOpened(terminal: .iterm2))
        #expect(env.pasteboardCopies == ["lumina session start --image mypy"])
        #expect(env.openAppCalls == [TerminalKind.iterm2.bundleIdentifier])
    }

    @Test func iterm2Launch_FailsWhenAppleScriptAndOpenBothFail() {
        let env = RecordingEnvironment()
        env.installed = [.iterm2]
        env.appleScriptResult = false
        env.openAppResult = false
        let launcher = TerminalLauncher(env: env)

        let outcome = launcher.launch(command: "x", preferenceRaw: "iterm2")
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("iTerm2"))
    }

    @Test func ghosttyLaunch_AlwaysUsesPasteboardPath() {
        // Ghostty / Warp don't have a stable scripting surface so we
        // always copy + open, even on the happy path. The AppleScript
        // runner should not be called.
        let env = RecordingEnvironment()
        env.installed = [.ghostty]
        env.openAppResult = true
        let launcher = TerminalLauncher(env: env)

        let outcome = launcher.launch(command: "cmd", preferenceRaw: "ghostty")
        #expect(outcome == .copiedAndOpened(terminal: .ghostty))
        #expect(env.appleScriptCalls.isEmpty, "Ghostty path must not invoke AppleScript")
        #expect(env.pasteboardCopies == ["cmd"])
    }

    @Test func ghosttyLaunch_FailsWhenAppMissing() {
        let env = RecordingEnvironment()
        env.installed = [.ghostty]
        env.openAppResult = false
        let launcher = TerminalLauncher(env: env)

        let outcome = launcher.launch(command: "cmd", preferenceRaw: "ghostty")
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("Ghostty"))
    }

    @Test func terminalAppLaunch_UsesAppleScriptOnSuccess() {
        let env = RecordingEnvironment()
        env.installed = [.terminal]
        env.appleScriptResult = true
        let launcher = TerminalLauncher(env: env)

        let outcome = launcher.launch(command: "x", preferenceRaw: "terminal")
        #expect(outcome == .executed(terminal: .terminal))
        #expect(env.appleScriptCalls.first?.contains("tell application \"Terminal\"") == true)
    }

    @Test func appleScriptEscaping_QuotesInCommandAreEscaped() {
        let env = RecordingEnvironment()
        env.installed = [.terminal]
        env.appleScriptResult = true
        let launcher = TerminalLauncher(env: env)

        _ = launcher.launch(
            command: "echo \"hi\" && ls",
            preferenceRaw: "terminal"
        )
        // The embedded quotes must be backslash-escaped so the
        // AppleScript string literal stays well-formed. A naive
        // concatenation would truncate `echo ` at the unescaped quote.
        let script = env.appleScriptCalls.first ?? ""
        #expect(script.contains("echo \\\"hi\\\" && ls"))
    }

    @Test func appleScriptEscaping_NewlinesCollapsedToSpace() {
        let env = RecordingEnvironment()
        env.installed = [.terminal]
        env.appleScriptResult = true
        let launcher = TerminalLauncher(env: env)

        _ = launcher.launch(command: "a\nb", preferenceRaw: "terminal")
        let script = env.appleScriptCalls.first ?? ""
        // Newline would break the AppleScript string literal; the
        // launcher collapses to a space so the caller's intent (two
        // steps) still semantically runs. Shell `&&`-joined commands
        // are the supported single-line idiom anyway.
        #expect(script.contains("a b"))
        #expect(!script.contains("a\nb"))
    }
}
