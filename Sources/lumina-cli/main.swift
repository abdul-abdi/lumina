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
            // Remove clones owned by this process. cleanOrphans() would skip
            // them because our process is still alive during the handler.
            // Delete PID files first so cleanOrphans sees them as orphans.
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
            // Restore default and re-raise so parent gets correct exit status
            signal(signum, SIG_DFL)
            raise(signum)
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(sig, &action, nil)
    }
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

    @Flag(name: .long, help: "Stream stdout/stderr in real time")
    var stream = false

    @Option(name: .long, help: "Timeout (e.g. 30s, 5m)")
    var timeout: String = "60s"

    @Option(name: .long, help: "Memory (e.g. 512MB, 1GB)")
    var memory: String = "512MB"

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int = 2

    func run() async throws {
        // sigaction covers SIGINT/SIGTERM, atexit covers normal exit.
        // SIGKILL is uncatchable — orphans from that are cleaned at next VM boot.
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

        let options = RunOptions(
            timeout: parsedTimeout,
            memory: parsedMemory,
            cpuCount: cpus
        )

        if stream {
            do {
                let chunks = Lumina.stream(command, options: options)
                for try await chunk in chunks {
                    switch chunk {
                    case .stdout(let data):
                        print(data, terminator: "")
                    case .stderr(let data):
                        FileHandle.standardError.write(Data(data.utf8))
                    case .exit(let code):
                        if code != 0 {
                            throw ExitCode(code)
                        }
                    }
                }
            } catch {
                try handleRunError(error, timeout: timeout)
            }
        } else {
            do {
                let result = try await Lumina.run(command, options: options)
                print(result.stdout, terminator: "")
                if !result.stderr.isEmpty {
                    FileHandle.standardError.write(Data(result.stderr.utf8))
                }
                if !result.success {
                    throw ExitCode(result.exitCode)
                }
            } catch {
                try handleRunError(error, timeout: timeout)
            }
        }
    }
}

// MARK: - Error Handling

/// Shared error handler for both streaming and non-streaming paths.
/// Handles LuminaError with specific messages, passes through ExitCode,
/// and catches anything else (including typed-throws that lost their type
/// crossing actor boundaries) with a generic message.
private func handleRunError(_ error: any Error, timeout: String) throws -> Never {
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
            // Remove existing image before re-pulling
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
            for name in names {
                print(name)
            }
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
