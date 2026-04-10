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
        return String(describing: luminaError)
    default:
        return String(describing: luminaError)
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
/// Priority: LUMINA_FORMAT env > --text flag > isatty() auto-detection.
func resolveOutputFormat(textFlag: Bool) -> OutputFormat {
    // 1. LUMINA_FORMAT env var takes highest priority
    if let envFormat = ProcessInfo.processInfo.environment["LUMINA_FORMAT"]?.lowercased() {
        switch envFormat {
        case "json": return .json
        case "text", "human": return .text
        default: break
        }
    }

    // 2. --text flag explicitly requests human-readable
    if textFlag { return .text }

    // 3. Auto-detect: TTY -> text, pipe -> JSON
    return isatty(STDOUT_FILENO) != 0 ? .text : .json
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
