// Sources/lumina-cli/CLI.swift
import ArgumentParser
import Foundation
import Lumina

@main
struct LuminaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lumina",
        abstract: "Native Apple Workload Runtime for Agents — subprocess.run() for virtual machines.",
        version: "0.2.2",
        subcommands: [Run.self, Pull.self, Images.self, Clean.self,
                      Session.self, Exec.self, SessionServe.self]
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

    @Option(name: .long, help: "Copy file into VM (local:remote, repeatable)")
    var copy: [String] = []

    @Option(name: .long, help: "Download file from VM after command (remote:local, repeatable)")
    var download: [String] = []

    @Option(name: .long, help: "Mount host directory into VM (host:guest, repeatable)")
    var mount: [String] = []

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

        var parsedUploads: [FileUpload] = []
        for spec in copy {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --copy '\(spec)'. Use local:remote format\n".utf8))
                throw ExitCode.failure
            }
            let localStr = String(spec[spec.startIndex..<colonIndex])
            let remote = String(spec[spec.index(after: colonIndex)...])
            let localURL = URL(fileURLWithPath: localStr)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                FileHandle.standardError.write(Data("lumina: file not found: \(localStr)\n".utf8))
                throw ExitCode.failure
            }
            // Detect executable files and set mode accordingly
            let mode = FileManager.default.isExecutableFile(atPath: localURL.path) ? "0755" : "0644"
            parsedUploads.append(FileUpload(localPath: localURL, remotePath: remote, mode: mode))
        }

        var parsedDownloads: [FileDownload] = []
        for spec in download {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --download '\(spec)'. Use remote:local format\n".utf8))
                throw ExitCode.failure
            }
            let remote = String(spec[spec.startIndex..<colonIndex])
            let localStr = String(spec[spec.index(after: colonIndex)...])
            let localURL = URL(fileURLWithPath: localStr)
            parsedDownloads.append(FileDownload(remotePath: remote, localPath: localURL))
        }

        var parsedMounts: [MountPoint] = []
        for spec in mount {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --mount '\(spec)'. Use host:guest format\n".utf8))
                throw ExitCode.failure
            }
            let hostStr = String(spec[spec.startIndex..<colonIndex])
            let guest = String(spec[spec.index(after: colonIndex)...])
            let hostURL = URL(fileURLWithPath: hostStr)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir), isDir.boolValue else {
                FileHandle.standardError.write(Data("lumina: not a directory: \(hostStr)\n".utf8))
                throw ExitCode.failure
            }
            parsedMounts.append(MountPoint(hostPath: hostURL, guestPath: guest))
        }

        let options = RunOptions(
            timeout: parsedTimeout,
            memory: parsedMemory,
            cpuCount: cpus,
            env: parsedEnv,
            uploads: parsedUploads,
            downloads: parsedDownloads,
            mounts: parsedMounts
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
        case .uploadFailed(let path, let reason):
            FileHandle.standardError.write(Data("lumina: upload failed for '\(path)': \(reason)\n".utf8))
        case .downloadFailed(let path, let reason):
            FileHandle.standardError.write(Data("lumina: download failed for '\(path)': \(reason)\n".utf8))
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

struct Images: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage cached images",
        subcommands: [ImageList.self, ImageCreate.self, ImageRemove.self, ImageInspect.self],
        defaultSubcommand: ImageList.self
    )
}

struct ImageList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List cached images")

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

struct ImageCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a custom image")

    @Argument(help: "Name for the new image")
    var name: String

    @Option(name: .long, help: "Base image to build from")
    var from: String = "default"

    @Option(name: [.customLong("run")], help: "Command to run for setup")
    var buildCommand: String

    func run() async throws {
        FileHandle.standardError.write(Data("Creating image '\(name)' from '\(from)'...\n".utf8))
        do {
            try await Lumina.createImage(name: name, from: from, command: buildCommand)
            print("Image '\(name)' created successfully.")
        } catch {
            FileHandle.standardError.write(Data("lumina: image create failed: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

struct ImageRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a cached image")

    @Argument(help: "Image name to remove")
    var name: String

    func run() throws {
        let store = ImageStore()
        do {
            try store.removeImage(name: name)
            print("Image '\(name)' removed.")
        } catch {
            FileHandle.standardError.write(Data("lumina: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

struct ImageInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Show image details")

    @Argument(help: "Image name")
    var name: String

    func run() throws {
        let store = ImageStore()
        let info = try store.inspect(name: name)
        let dict: [String: Any] = [
            "name": info.name,
            "base": info.base ?? "none",
            "command": info.command ?? "none",
            "size_bytes": info.sizeBytes,
            "created": ISO8601DateFormatter().string(from: info.created)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
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

// MARK: - Session

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage persistent VM sessions",
        subcommands: [SessionStart.self, SessionStop.self, SessionList.self]
    )
}

struct SessionStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start a new persistent session")

    @Option(name: .long, help: "Image to boot from")
    var image: String = "default"

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int = 2

    @Option(name: .long, help: "Memory (e.g. 512MB, 1GB)")
    var memory: String = "512MB"

    @Option(name: .long, help: "Volume to mount (name:guest_path, repeatable)")
    var volume: [String] = []

    func run() async throws {
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
                throw ExitCode.failure
            }
        }

        guard let parsedMemory = parseMemory(memory) else {
            FileHandle.standardError.write(Data("lumina: invalid memory '\(memory)'\n".utf8))
            throw ExitCode.failure
        }

        var parsedVolumes: [VolumeMount] = []
        for spec in volume {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --volume '\(spec)'. Use name:guest_path format\n".utf8))
                throw ExitCode.failure
            }
            let name = String(spec[spec.startIndex..<colonIndex])
            let guestPath = String(spec[spec.index(after: colonIndex)...])
            parsedVolumes.append(VolumeMount(name: name, guestPath: guestPath))
        }

        let sid = UUID().uuidString
        let execPath = ProcessInfo.processInfo.arguments[0]

        // Spawn background session process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = [
            "_session-serve",
            "--sid", sid,
            "--image", image,
            "--cpus", String(cpus),
            "--memory", String(parsedMemory),
        ]
        for v in parsedVolumes {
            process.arguments! += ["--volume", "\(v.name):\(v.guestPath)"]
        }

        // Detach from terminal
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("lumina: failed to start session: \(error)\n".utf8))
            throw ExitCode.failure
        }

        // Wait for the socket to appear (session process boots VM)
        let paths = SessionPaths(sid: sid)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: paths.socket.path) {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        guard FileManager.default.fileExists(atPath: paths.socket.path) else {
            FileHandle.standardError.write(Data("lumina: session failed to start within 30s\n".utf8))
            throw ExitCode.failure
        }

        // Output session ID
        let format = resolveOutputFormat(textFlag: false)
        switch format {
        case .json:
            let output = try JSONSerialization.data(withJSONObject: ["sid": sid], options: [.sortedKeys])
            print(String(data: output, encoding: .utf8)!)
        case .text:
            print(sid)
        }
    }
}

struct SessionStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a running session")

    @Argument(help: "Session ID")
    var sid: String

    func run() async throws {
        let client = SessionClient()
        do {
            try client.connect(sid: sid)
            try client.send(.shutdown)
            _ = try? client.receive()
            client.disconnect()
        } catch let error as LuminaError {
            switch error {
            case .sessionNotFound:
                FileHandle.standardError.write(Data("lumina: session '\(sid)' not found\n".utf8))
            case .sessionDead:
                FileHandle.standardError.write(Data("lumina: session '\(sid)' is dead (cleaned up)\n".utf8))
            default:
                FileHandle.standardError.write(Data("lumina: \(error)\n".utf8))
            }
            throw ExitCode.failure
        }
    }
}

struct SessionList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List active sessions")

    @Flag(name: .long, help: "Force human-readable text output")
    var text = false

    func run() throws {
        let sessions = SessionPaths.listAll()
        let format = resolveOutputFormat(textFlag: text)
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(sessions),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .text:
            if sessions.isEmpty {
                print("No active sessions.")
            } else {
                for s in sessions {
                    let status = s.status == .running ? "running" : "dead"
                    print("\(s.sid)\t\(s.image)\t\(status)")
                }
            }
        }
    }
}

// MARK: - Exec

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Execute a command in a running session")

    @Argument(help: "Session ID")
    var sid: String

    @Argument(help: "Command to run")
    var command: String

    @Flag(name: .long, help: "Stream output in real time")
    var stream = false

    @Flag(name: .long, help: "Force human-readable text output")
    var text = false

    @Option(name: .long, help: "Timeout (e.g. 30s, 5m)")
    var timeout: String = "60s"

    @Option(name: [.short, .long], help: "Environment variable (KEY=VAL, repeatable)")
    var env: [String] = []

    @Option(name: .long, help: "Copy file into VM (local:remote, repeatable)")
    var copy: [String] = []

    @Option(name: .long, help: "Download file from VM (remote:local, repeatable)")
    var download: [String] = []

    func run() async throws {
        guard let parsedTimeout = parseDuration(timeout) else {
            FileHandle.standardError.write(Data("lumina: invalid timeout '\(timeout)'\n".utf8))
            throw ExitCode.failure
        }
        let timeoutSecs = Int(parsedTimeout.components.seconds)

        var parsedEnv: [String: String] = [:]
        for pair in env {
            guard let eqIndex = pair.firstIndex(of: "=") else {
                FileHandle.standardError.write(Data("lumina: invalid env '\(pair)'. Use KEY=VAL\n".utf8))
                throw ExitCode.failure
            }
            parsedEnv[String(pair[..<eqIndex])] = String(pair[pair.index(after: eqIndex)...])
        }

        let client = SessionClient()
        do {
            try client.connect(sid: sid)
        } catch let error as LuminaError {
            switch error {
            case .sessionNotFound:
                FileHandle.standardError.write(Data("lumina: session '\(sid)' not found\n".utf8))
            case .sessionDead:
                FileHandle.standardError.write(Data("lumina: session '\(sid)' is dead (cleaned up)\n".utf8))
            default:
                FileHandle.standardError.write(Data("lumina: \(error)\n".utf8))
            }
            throw ExitCode.failure
        }
        defer { client.disconnect() }

        // Handle file uploads before exec
        for spec in copy {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --copy '\(spec)'\n".utf8))
                throw ExitCode.failure
            }
            let localStr = String(spec[..<colonIndex])
            let remote = String(spec[spec.index(after: colonIndex)...])
            try client.send(.upload(localPath: localStr, remotePath: remote))
            let resp = try client.receive()
            if case .error(let msg) = resp {
                FileHandle.standardError.write(Data("lumina: upload failed: \(msg)\n".utf8))
                throw ExitCode.failure
            }
        }

        // Execute
        let format = resolveOutputFormat(textFlag: text)
        try client.send(.exec(cmd: command, timeout: timeoutSecs, env: parsedEnv))

        while true {
            let response = try client.receive()
            switch response {
            case .output(let outputStream, let data):
                switch format {
                case .json:
                    printNDJSON(["stream": outputStream.rawValue, "data": data])
                case .text:
                    if outputStream == .stdout {
                        print(data, terminator: "")
                    } else {
                        FileHandle.standardError.write(Data(data.utf8))
                    }
                }
            case .exit(let code, let durationMs):
                switch format {
                case .json:
                    printNDJSON(["exit_code": Int(code), "duration_ms": durationMs])
                case .text:
                    break
                }

                // Handle file downloads after exec
                for spec in download {
                    guard let colonIndex = spec.firstIndex(of: ":") else { continue }
                    let remote = String(spec[..<colonIndex])
                    let localStr = String(spec[spec.index(after: colonIndex)...])
                    try client.send(.download(remotePath: remote, localPath: localStr))
                    let dlResp = try client.receive()
                    if case .error(let msg) = dlResp {
                        FileHandle.standardError.write(Data("lumina: download failed: \(msg)\n".utf8))
                    }
                }

                if code != 0 { throw ExitCode(code) }
                return
            case .error(let message):
                FileHandle.standardError.write(Data("lumina: \(message)\n".utf8))
                throw ExitCode.failure
            default:
                continue
            }
        }
    }
}

// Parsing helpers (parseDuration, parseMemory) are in Lumina/Types.swift
