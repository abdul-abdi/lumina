// Sources/lumina-cli/Helpers.swift
import Foundation
import Lumina

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

/// Print an NDJSON line (used for streaming output).
func printNDJSON(_ dict: [String: Any]) {
    // Use JSONSerialization for heterogeneous dicts, then ensure no literal newlines
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .fragmentsAllowed]),
          var str = String(data: data, encoding: .utf8) else { return }
    // JSONSerialization doesn't escape newlines in string values -- replace them
    str = str.replacingOccurrences(of: "\n", with: "\\n")
    str = str.replacingOccurrences(of: "\r", with: "\\r")
    str = str.replacingOccurrences(of: "\t", with: "\\t")
    print(str)
    // Flush stdout for real-time streaming
    fflush(stdout)
}
