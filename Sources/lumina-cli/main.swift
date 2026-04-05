// Sources/lumina-cli/main.swift
import ArgumentParser
import Foundation
import Lumina

// Install signal handlers via sigaction. sigaction is stronger than signal() —
// it can't be silently overridden. The handler cleans orphaned COW clones, then
// re-raises the signal with default disposition so the parent process gets the
// correct wait status (128 + signal).
private func installSignalHandlers() {
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

// MARK: - Output Format

/// Determine output format: JSON (for agents/pipes) or text (for humans/TTYs).
/// Priority: LUMINA_FORMAT env > --text flag > isatty() auto-detection.
private enum OutputFormat {
    case json
    case text
}

private func resolveOutputFormat(textFlag: Bool) -> OutputFormat {
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

    // 3. Auto-detect: TTY → text, pipe → JSON
    return isatty(STDOUT_FILENO) != 0 ? .text : .json
}

@main
struct LuminaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lumina",
        abstract: "Native Apple Workload Runtime for Agents — subprocess.run() for virtual machines.",
        version: "0.2.0",
        subcommands: [Run.self, Pull.self, Images.self, Clean.self]
    )
}

// MARK: - Run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command in a disposable VM")

    @Argument(help: "Command to run in the VM")
    var command: String

    @Flag(name: .long, help: "Stream output in real time (NDJSON when piped, raw when TTY)")
    var stream = false

    @Flag(name: .long, help: "Force human-readable text output (default when TTY)")
    var text = false

    @Option(name: .long, help: "Timeout (e.g. 30s, 5m)")
    var timeout: String = "60s"

    @Option(name: .long, help: "Memory (e.g. 512MB, 1GB)")
    var memory: String = "512MB"

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int = 2

    @Option(name: [.short, .long], help: "Environment variable (KEY=VAL, repeatable)")
    var env: [String] = []

    func run() async throws {
        installSignalHandlers()
        atexit { DiskClone.cleanOrphans() }

        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("lumina: command cannot be empty\n".utf8))
            throw ExitCode.failure
        }

        // Auto-pull image if not present
        let puller = ImagePuller()
        if !puller.imageExists() {
            FileHandle.standardError.write(Data("Image not found. Pulling default image...\n".utf8))
            do {
                try await puller.pull { msg in
                    FileHandle.standardError.write(Data("\(msg)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("lumina: auto-pull failed: \(error)\n".utf8))
                FileHandle.standardError.write(Data("Build locally: cd Guest && sudo ./build-image.sh\n".utf8))
                throw ExitCode.failure
            }
        }

        guard let parsedTimeout = parseDuration(timeout) else {
            FileHandle.standardError.write(Data("lumina: invalid timeout '\(timeout)'. Use e.g. 30s, 5m\n".utf8))
            throw ExitCode.failure
        }

        guard let parsedMemory = parseMemory(memory) else {
            FileHandle.standardError.write(Data("lumina: invalid memory '\(memory)'. Use e.g. 512MB, 1GB\n".utf8))
            throw ExitCode.failure
        }

        var parsedEnv: [String: String] = [:]
        for pair in env {
            guard let eqIndex = pair.firstIndex(of: "=") else {
                FileHandle.standardError.write(Data("lumina: invalid env '\(pair)'. Use KEY=VAL format\n".utf8))
                throw ExitCode.failure
            }
            let key = String(pair[pair.startIndex..<eqIndex])
            let value = String(pair[pair.index(after: eqIndex)...])
            parsedEnv[key] = value
        }

        let options = RunOptions(
            timeout: parsedTimeout,
            memory: parsedMemory,
            cpuCount: cpus,
            env: parsedEnv
        )

        let format = resolveOutputFormat(textFlag: text)

        if stream {
            try await runStreaming(options: options, format: format)
        } else {
            try await runBuffered(options: options, format: format)
        }
    }

    // MARK: - Buffered (non-streaming)

    private func runBuffered(options: RunOptions, format: OutputFormat) async throws {
        let start = ContinuousClock.now
        do {
            let result = try await Lumina.run(command, options: options)
            let ms = millisSince(start)
            switch format {
            case .json:
                printResultJSON(result, durationMs: ms)
            case .text:
                print(result.stdout, terminator: "")
                if !result.stderr.isEmpty {
                    FileHandle.standardError.write(Data(result.stderr.utf8))
                }
            }
            if !result.success {
                throw ExitCode(result.exitCode)
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            let ms = millisSince(start)
            switch format {
            case .json:
                printErrorJSON(error, durationMs: ms)
            case .text:
                try handleTextError(error, timeout: timeout)
            }
            throw ExitCode.failure
        }
    }

    // MARK: - Streaming

    private func runStreaming(options: RunOptions, format: OutputFormat) async throws {
        let start = ContinuousClock.now
        do {
            let chunks = Lumina.stream(command, options: options)
            for try await chunk in chunks {
                switch format {
                case .json:
                    // NDJSON: one JSON object per line
                    switch chunk {
                    case .stdout(let data):
                        printNDJSON(["stream": "stdout", "data": data])
                    case .stderr(let data):
                        printNDJSON(["stream": "stderr", "data": data])
                    case .exit(let code):
                        printNDJSON(["exit_code": Int(code), "duration_ms": millisSince(start)])
                        if code != 0 { throw ExitCode(code) }
                    }
                case .text:
                    switch chunk {
                    case .stdout(let data):
                        print(data, terminator: "")
                    case .stderr(let data):
                        FileHandle.standardError.write(Data(data.utf8))
                    case .exit(let code):
                        if code != 0 { throw ExitCode(code) }
                    }
                }
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            switch format {
            case .json:
                printNDJSON(["error": String(describing: error), "duration_ms": millisSince(start)])
            case .text:
                try handleTextError(error, timeout: timeout)
            }
            throw ExitCode.failure
        }
    }
}

// MARK: - Error Handling (text mode)

private func handleTextError(_ error: any Error, timeout: String) throws -> Never {
    if let luminaError = error as? LuminaError {
        switch luminaError {
        case .timeout:
            FileHandle.standardError.write(Data("lumina: command timed out after \(timeout)\n".utf8))
        case .guestCrashed(let serialOutput):
            FileHandle.standardError.write(Data("lumina: guest crashed\n--- serial output ---\n\(serialOutput)\n--- end serial ---\n".utf8))
        default:
            FileHandle.standardError.write(Data("lumina: \(luminaError)\n".utf8))
        }
    } else if let exitCode = error as? ExitCode {
        throw exitCode
    } else {
        FileHandle.standardError.write(Data("lumina: \(error)\n".utf8))
    }
    throw ExitCode.failure
}

// MARK: - JSON Output

private struct ResultJSON: Encodable {
    var stdout: String?
    var stderr: String?
    var exit_code: Int?
    var error: String?
    var duration_ms: Int
}

private func printResultJSON(_ result: RunResult, durationMs: Int) {
    let r = ResultJSON(
        stdout: result.stdout,
        stderr: result.stderr,
        exit_code: Int(result.exitCode),
        duration_ms: durationMs
    )
    encodeAndPrint(r)
}

private func printErrorJSON(_ error: any Error, durationMs: Int) {
    let r = ResultJSON(error: String(describing: error), duration_ms: durationMs)
    encodeAndPrint(r)
}

/// Print an NDJSON line (used for streaming output).
private func printNDJSON(_ dict: [String: Any]) {
    // Use JSONSerialization for heterogeneous dicts, then ensure no literal newlines
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .fragmentsAllowed]),
          var str = String(data: data, encoding: .utf8) else { return }
    // JSONSerialization doesn't escape newlines in string values — replace them
    str = str.replacingOccurrences(of: "\n", with: "\\n")
    str = str.replacingOccurrences(of: "\r", with: "\\r")
    str = str.replacingOccurrences(of: "\t", with: "\\t")
    print(str)
    // Flush stdout for real-time streaming
    fflush(stdout)
}

private func encodeAndPrint<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    if let data = try? encoder.encode(value),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

private func millisSince(_ start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
}

// MARK: - Pull

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pull the default Alpine image from GitHub Releases")

    @Flag(name: .long, help: "Re-download even if image already exists")
    var force = false

    func run() async throws {
        let puller = ImagePuller()

        if puller.imageExists() && !force {
            print("Image 'default' already exists. Use --force to re-download.")
            return
        }

        if puller.imageExists() && force {
            ImageStore().clean(name: "default")
        }

        do {
            try await puller.pull { msg in
                print(msg)
            }
            print("Done! Run 'lumina run \"echo hello\"' to test.")
        } catch {
            FileHandle.standardError.write(Data("lumina pull: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

// MARK: - Images

struct Images: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List cached images")

    func run() throws {
        let store = ImageStore()
        let names = store.list()
        if names.isEmpty {
            print("No images found. Run 'lumina pull' first.")
        } else {
            for name in names { print(name) }
        }
    }
}

// MARK: - Clean

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove orphaned COW clones and stale images")

    func run() throws {
        let removed = DiskClone.cleanOrphans()
        if removed > 0 {
            print("Removed \(removed) orphaned clone(s).")
        } else {
            print("No orphaned clones found.")
        }
    }
}

// Parsing helpers (parseDuration, parseMemory) are in Lumina/Types.swift
