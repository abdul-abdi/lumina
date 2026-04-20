// Sources/lumina-cli/Helpers.swift
import Foundation
import Lumina

// MARK: - Error Descriptions

/// Return a human-friendly description for LuminaError, adding context where possible.
func friendlyError(_ error: any Error) -> String {
    guard let luminaError = error as? LuminaError else {
        return String(describing: error)
    }
    switch luminaError {
    case .bootFailed(let underlying):
        // Match on structured NSError domain/code, not fragile string content.
        // ENOTSUP (45) in NSPOSIXErrorDomain means the Virtualization framework
        // rejected the VM — typically because macOS hit its concurrent VM limit.
        let nsError = underlying as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOTSUP) {
            return "bootFailed: VM limit reached — macOS restricts the number of concurrent VMs. Reduce parallel runs or use sessions."
        }
        return luminaError.localizedDescription
    default:
        return luminaError.localizedDescription
    }
}

// MARK: - Signal Handlers (shared across CLI commands)

/// Install signal handlers via sigaction. Cleans orphaned COW clones on
/// SIGINT/SIGTERM, then re-raises with default disposition so the parent
/// process sees the correct wait status (128 + signal).
func installSignalHandlers() {
    for sig: Int32 in [SIGINT, SIGTERM] {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { signum in
            let pid = "\(getpid())"
            let runsDir = DiskClone.defaultRunsDir
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: runsDir, includingPropertiesForKeys: nil
            ) {
                for entry in entries {
                    let pidFile = entry.appendingPathComponent(".pid")
                    if let content = try? String(contentsOf: pidFile, encoding: .utf8),
                       content.trimmingCharacters(in: .whitespacesAndNewlines) == pid {
                        try? FileManager.default.removeItem(at: entry)
                    }
                }
            }
            signal(signum, SIG_DFL)
            raise(signum)
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(sig, &action, nil)
    }
}

// MARK: - Signal Forwarding (for session exec)

/// Install signal forwarding that sends a cancel message to the session client
/// on SIGINT/SIGTERM. Returns a cleanup closure that removes the signal sources.
func installSignalForwarding(client: SessionClient) -> () -> Void {
    // Ignore default signal handling — we'll handle it ourselves
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let queue = DispatchQueue(label: "com.lumina.signal")
    let sources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        source.setEventHandler {
            // Send cancel to guest via session IPC
            try? client.send(.cancel(signal: Int32(sig), gracePeriod: 5))

            // After sending cancel, restore default handler and re-raise
            // so the process eventually exits with the correct signal status.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Foundation.signal(sig, SIG_DFL)
                raise(sig)
            }
        }
        source.resume()
        return source
    }

    return {
        for source in sources { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

// MARK: - Output Format (shared across CLI commands)

enum OutputFormat {
    case json
    case text
}

/// Determine output format: JSON (for agents/pipes) or text (for humans/TTYs).
/// Priority: LUMINA_FORMAT env > isatty() auto-detection.
func resolveOutputFormat() -> OutputFormat {
    // 1. LUMINA_FORMAT env var takes highest priority
    if let envFormat = ProcessInfo.processInfo.environment["LUMINA_FORMAT"]?.lowercased() {
        switch envFormat {
        case "json": return .json
        case "text", "human": return .text
        default: break
        }
    }

    // 2. Auto-detect: TTY -> text, pipe -> JSON
    return isatty(STDOUT_FILENO) != 0 ? .text : .json
}

// MARK: - Env Var Defaults
//
// Priority: CLI flag > env var > built-in default.
// Env vars: LUMINA_MEMORY, LUMINA_CPUS, LUMINA_TIMEOUT, LUMINA_DISK_SIZE

import Lumina

/// Resolve memory: CLI flag (if changed from default) > LUMINA_MEMORY env > built-in 1GB.
func resolveMemory(flag: String) -> String {
    if flag != "1GB" { return flag }
    return ProcessInfo.processInfo.environment["LUMINA_MEMORY"] ?? flag
}

/// Resolve CPU count: CLI flag (if changed from default) > LUMINA_CPUS env > built-in 2.
func resolveCpus(flag: Int) -> Int {
    if flag != 2 { return flag }
    if let envStr = ProcessInfo.processInfo.environment["LUMINA_CPUS"],
       let envVal = Int(envStr), envVal > 0 {
        return envVal
    }
    return flag
}

/// Resolve timeout: CLI flag (if changed from default) > LUMINA_TIMEOUT env > built-in default.
func resolveTimeout(flag: String, defaultValue: String) -> String {
    if flag != defaultValue { return flag }
    return ProcessInfo.processInfo.environment["LUMINA_TIMEOUT"] ?? flag
}

/// Resolve disk size: CLI flag > LUMINA_DISK_SIZE env > nil (use image default).
func resolveDiskSize(flag: String?) -> String? {
    if let flag { return flag }
    return ProcessInfo.processInfo.environment["LUMINA_DISK_SIZE"]
}

// MARK: - Streaming Mode (text format only)
//
// Default: TTY = stream (humans want real-time), pipe = buffer.
// Override: LUMINA_STREAM=0|1 env var.
// JSON format uses the unified envelope (buffered) by default; set
// LUMINA_OUTPUT=ndjson for legacy per-chunk NDJSON streaming.

/// Resolve streaming mode for text output: LUMINA_STREAM env > isatty auto-detect.
func resolveStreaming() -> Bool {
    if let envVal = ProcessInfo.processInfo.environment["LUMINA_STREAM"]?.lowercased() {
        return envVal == "1" || envVal == "true"
    }
    return isatty(STDOUT_FILENO) != 0
}

// MARK: - Session ID Parsing

/// Parse a session ID from either a bare UUID string or a JSON {"sid":"UUID"} object.
/// Allows agents to pipe `session start` output directly without JSON extraction:
///   SID=$(lumina session start) && lumina exec "$SID" "cmd"
/// Works with both bare UUID (LUMINA_FORMAT=text) and JSON (default piped output).
func parseSID(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let sid = json["sid"] as? String {
        return sid
    }
    return trimmed
}

// MARK: - Stdin Auto-Detect
//
// Default: TTY = closed (send EOF immediately, matches `cat </dev/null`),
// pipe = streamed (agents pipe data in, matches shell conventions).

/// Resolve stdin source: if host stdin is a TTY, return `.closed` so the guest
/// sees EOF immediately. Otherwise, return a `.source` that reads from
/// FileHandle.standardInput in chunks and closes on EOF.
func resolveStdin() -> Stdin {
    if isatty(fileno(stdin)) != 0 {
        return .closed
    }
    let handle = FileHandle.standardInput
    return .source { @Sendable in
        // availableData blocks until data is ready or EOF. Returns empty
        // Data on EOF, which we signal to the pump as nil.
        let chunk = handle.availableData
        return chunk.isEmpty ? nil : chunk
    }
}

// MARK: - Legacy Output Mode

/// Check if legacy NDJSON output is requested for exec.
/// `LUMINA_OUTPUT=ndjson` preserves pre-v0.6.0 streaming behavior for exec when piped.
/// Default (absent or any other value) = unified envelope. Removed in v0.8.0.
func useLegacyExecOutput() -> Bool {
    ProcessInfo.processInfo.environment["LUMINA_OUTPUT"]?.lowercased() == "ndjson"
}

// MARK: - NDJSON Output Types (streaming / session exec)

/// Stream chunk: stdout or stderr data.
struct StreamChunk: Encodable {
    var stream: String
    var data: String
}

/// Exit status for streaming / session exec.
struct ExitChunk: Encodable {
    var exit_code: Int
    var duration_ms: Int
}

/// Error for streaming / session exec.
struct ErrorChunk: Encodable {
    var error: String
    var duration_ms: Int
}

/// Print a Codable value as a single NDJSON line, flushing immediately for real-time output.
/// Uses JSONEncoder which always properly escapes control characters (\n, \r, \t, etc.).
func printNDJSONLine<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    if let data = try? encoder.encode(value),
       let str = String(data: data, encoding: .utf8) {
        print(str)
        fflush(stdout)
    }
}

// MARK: - Raw Terminal Mode (PTY support)

#if canImport(Darwin)
import Darwin
#endif

/// Module-level saved termios used by PTY signal handlers. Signal handlers run on
/// a dispatch queue and need access to the original termios to restore the
/// terminal before re-raising the signal. Safe because at most one PTY session
/// is active per CLI process.
nonisolated(unsafe) private var savedTermios: termios?

/// Switch the terminal (stdin) into raw mode, returning the original termios so
/// the caller can restore it. Returns nil if stdin is not a TTY or the ioctl fails.
///
/// Caller contract: always pair with `restoreTerminal(_:)` via `defer` to
/// guarantee the terminal is reset on exit — including error paths.
func enableRawMode() -> termios? {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
    savedTermios = original

    var raw = original
    cfmakeraw(&raw)
    // Keep ISIG so Ctrl-C still generates SIGINT on the host side — the PTY
    // code translates that into a pty_input(0x03) sent to the guest.
    raw.c_lflag |= UInt(ISIG)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
        savedTermios = nil
        return nil
    }
    return original
}

/// Restore the terminal (stdin) to the original termios captured by `enableRawMode`.
func restoreTerminal(_ original: termios) {
    var t = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
    savedTermios = nil
}

/// Return the current terminal window size (cols, rows) from stdout, or nil if
/// stdout is not attached to a TTY.
func getTerminalSize() -> (cols: Int, rows: Int)? {
    var ws = winsize()
    // `TIOCGWINSZ` type varies by SDK (UInt on some, UInt32 on others); force to UInt.
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 else { return nil }
    return (cols: Int(ws.ws_col), rows: Int(ws.ws_row))
}

/// Install PTY signal handlers using DispatchSource (C `signal()` callbacks
/// cannot capture state). SIGINT/SIGTERM restore termios then re-raise with
/// default disposition so the parent process observes the correct wait status.
/// SIGWINCH invokes `onResize` with the fresh terminal size.
///
/// The caller MUST retain the returned cleanup closure and invoke it on exit
/// (typically via `defer`) so the DispatchSources are cancelled and the signal
/// dispositions are restored.
func installPtySignalHandlers(
    onResize: @escaping @Sendable (Int, Int) -> Void
) -> () -> Void {
    let queue = DispatchQueue(label: "com.lumina.pty-signals")

    // SIGINT/SIGTERM: restore terminal, then re-raise with default disposition
    let termSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
        Foundation.signal(sig, SIG_IGN) // Let the dispatch source deliver it
        let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        source.setEventHandler {
            if var saved = savedTermios {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
                savedTermios = nil
            }
            Foundation.signal(sig, SIG_DFL)
            raise(sig)
        }
        source.resume()
        return source
    }

    // SIGWINCH: report new size to caller
    Foundation.signal(SIGWINCH, SIG_IGN)
    let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
    winchSource.setEventHandler {
        if let size = getTerminalSize() {
            onResize(size.cols, size.rows)
        }
    }
    winchSource.resume()

    return {
        for source in termSources { source.cancel() }
        winchSource.cancel()
        Foundation.signal(SIGINT, SIG_DFL)
        Foundation.signal(SIGTERM, SIG_DFL)
        Foundation.signal(SIGWINCH, SIG_DFL)
    }
}
