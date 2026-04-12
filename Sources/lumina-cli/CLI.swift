// Sources/lumina-cli/CLI.swift
import ArgumentParser
import Foundation
import Lumina

@main
struct LuminaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lumina",
        abstract: "Native Apple Workload Runtime for Agents — subprocess.run() for virtual machines.",
        version: "0.5.0",
        subcommands: [Run.self, Pull.self, Images.self, Clean.self,
                      Session.self, Exec.self, SessionServe.self,
                      Volume.self, NetworkCmd.self]
    )
}

// MARK: - Run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command in a disposable VM")

    @Argument(help: "Command to run in the VM")
    var command: String

    @Option(name: .long, help: "Image to boot from")
    var image: String = "default"

    @Flag(name: .long, help: "Stream output in real time (NDJSON when piped, raw when TTY)")
    var stream = false

    @Flag(name: .long, help: "Force human-readable text output (default when TTY)")
    var text = false

    @Option(name: .long, help: "Command timeout, excludes ~2s boot time (e.g. 30s, 5m)")
    var timeout: String = "60s"

    @Option(name: .long, help: "Memory (e.g. 512MB, 1GB)")
    var memory: String = "512MB"

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int = 2

    @Option(name: [.short, .long], help: "Environment variable (KEY=VAL, repeatable)")
    var env: [String] = []

    @Option(name: .long, help: "Copy file into VM (local:remote, repeatable)")
    var copy: [String] = []

    @Option(name: .long, help: "Copy directory into VM (local:remote, repeatable)")
    var copyDir: [String] = []

    @Option(name: .long, help: "Download file from VM after command (remote:local, repeatable)")
    var download: [String] = []

    @Option(name: .long, help: "Download directory from VM after command (remote:local, repeatable)")
    var downloadDir: [String] = []

    @Option(name: .long, help: "Mount host directory into VM (host:guest, repeatable)")
    var mount: [String] = []

    @Option(name: .long, help: "Mount named volume (name:guest_path, repeatable)")
    var volume: [String] = []

    @Option(name: .long, help: "Working directory inside the VM")
    var workdir: String? = nil

    @Flag(name: .long, help: "Enable Rosetta for x86_64 binary translation")
    var rosetta = false

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

        var parsedDirUploads: [DirectoryUpload] = []
        for spec in copyDir {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --copy-dir '\(spec)'. Use local:remote format\n".utf8))
                throw ExitCode.failure
            }
            let localStr = String(spec[spec.startIndex..<colonIndex])
            let remote = String(spec[spec.index(after: colonIndex)...])
            let localURL = URL(fileURLWithPath: localStr)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir), isDir.boolValue else {
                FileHandle.standardError.write(Data("lumina: not a directory: \(localStr)\n".utf8))
                throw ExitCode.failure
            }
            parsedDirUploads.append(DirectoryUpload(localPath: localURL, remotePath: remote))
        }

        var parsedDirDownloads: [DirectoryDownload] = []
        for spec in downloadDir {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --download-dir '\(spec)'. Use remote:local format\n".utf8))
                throw ExitCode.failure
            }
            let remote = String(spec[spec.startIndex..<colonIndex])
            let localStr = String(spec[spec.index(after: colonIndex)...])
            let localURL = URL(fileURLWithPath: localStr)
            parsedDirDownloads.append(DirectoryDownload(remotePath: remote, localPath: localURL))
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

        // Resolve --volume flags (name:guest_path -> host_path:guest_path)
        let volumeStore = VolumeStore()
        for spec in volume {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --volume '\(spec)'. Use name:guest_path\n".utf8))
                throw ExitCode.failure
            }
            let name = String(spec[..<colonIndex])
            let guestPath = String(spec[spec.index(after: colonIndex)...])
            guard let hostDir = volumeStore.resolve(name: name) else {
                FileHandle.standardError.write(Data("lumina: volume '\(name)' not found\n".utf8))
                throw ExitCode.failure
            }
            volumeStore.touch(name: name)
            parsedMounts.append(MountPoint(hostPath: hostDir, guestPath: guestPath))
        }

        let options = RunOptions(
            timeout: parsedTimeout,
            memory: parsedMemory,
            cpuCount: cpus,
            image: image,
            env: parsedEnv,
            uploads: parsedUploads,
            downloads: parsedDownloads,
            directoryUploads: parsedDirUploads,
            directoryDownloads: parsedDirDownloads,
            mounts: parsedMounts,
            workingDirectory: workdir,
            rosetta: rosetta
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
                printErrorJSON(error, durationMs: ms, friendly: true)
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
                        printNDJSONLine(StreamChunk(stream: "stdout", data: data))
                    case .stderr(let data):
                        printNDJSONLine(StreamChunk(stream: "stderr", data: data))
                    case .exit(let code):
                        printNDJSONLine(ExitChunk(exit_code: Int(code), duration_ms: millisSince(start)))
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
                printNDJSONLine(ErrorChunk(error: friendlyError(error), duration_ms: millisSince(start)))
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

private func printErrorJSON(_ error: any Error, durationMs: Int, friendly: Bool = false) {
    let msg = friendly ? friendlyError(error) : String(describing: error)
    let r = ResultJSON(error: msg, duration_ms: durationMs)
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
    (ContinuousClock.now - start).totalMilliseconds
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

    @Option(name: [.customLong("run")], help: "Command to run for setup (repeatable)")
    var buildCommands: [String]

    @Option(name: .long, help: "Timeout for build command (e.g. 60s, 5m)")
    var timeout: String = "5m"

    func run() async throws {
        guard let parsedTimeout = parseDuration(timeout) else {
            FileHandle.standardError.write(Data("lumina: invalid timeout '\(timeout)'. Use e.g. 60s, 5m\n".utf8))
            throw ExitCode.failure
        }

        guard !buildCommands.isEmpty else {
            FileHandle.standardError.write(Data("lumina: at least one --run command is required\n".utf8))
            throw ExitCode.failure
        }

        let stepLabel = buildCommands.count == 1 ? "1 step" : "\(buildCommands.count) steps"
        FileHandle.standardError.write(Data("Creating image '\(name)' from '\(from)' (\(stepLabel))...\n".utf8))
        do {
            var opts = RunOptions()
            opts.timeout = parsedTimeout
            if buildCommands.count == 1 {
                try await Lumina.createImage(name: name, from: from, command: buildCommands[0], options: opts)
            } else {
                try await Lumina.createImage(name: name, from: from, commands: buildCommands, options: opts)
            }
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
        struct ImageInspectOutput: Encodable {
            var name: String
            var base: String
            var command: String
            var size_bytes: UInt64
            var created: String
        }
        let output = ImageInspectOutput(
            name: info.name,
            base: info.base ?? "none",
            command: info.command ?? "none",
            size_bytes: info.sizeBytes,
            created: ISO8601DateFormatter().string(from: info.created)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(output),
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

    @Option(name: .long, help: "Max time to wait for VM to boot (e.g. 30s, 2m)")
    var bootTimeout: String = "60s"

    @Flag(name: .long, help: "Enable Rosetta for x86_64 binary translation")
    var rosetta = false

    func run() async throws {
        // Check if requested image exists before spawning background process
        let puller = ImagePuller()
        if !puller.imageExists(name: image) {
            if image == "default" {
                FileHandle.standardError.write(Data("Image not found. Pulling default image...\n".utf8))
                do {
                    try await puller.pull { msg in
                        FileHandle.standardError.write(Data("\(msg)\n".utf8))
                    }
                } catch {
                    FileHandle.standardError.write(Data("lumina: auto-pull failed: \(error)\n".utf8))
                    throw ExitCode.failure
                }
            } else {
                FileHandle.standardError.write(Data("lumina: image '\(image)' not found. Use 'lumina images list' to see available images.\n".utf8))
                throw ExitCode.failure
            }
        }

        guard let parsedMemory = parseMemory(memory) else {
            FileHandle.standardError.write(Data("lumina: invalid memory '\(memory)'\n".utf8))
            throw ExitCode.failure
        }

        guard let parsedBootTimeout = parseDuration(bootTimeout) else {
            FileHandle.standardError.write(Data("lumina: invalid boot-timeout '\(bootTimeout)'. Use e.g. 30s, 2m\n".utf8))
            throw ExitCode.failure
        }
        let bootTimeoutSecs = Int(parsedBootTimeout.components.seconds)

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
        if rosetta {
            process.arguments! += ["--rosetta"]
        }

        // Capture stderr from child process so boot failures are surfaced
        // instead of hidden behind a generic timeout message.
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("lumina: failed to start session: \(error)\n".utf8))
            throw ExitCode.failure
        }

        // Wait for the socket to appear (session process boots VM)
        let paths = SessionPaths(sid: sid)
        let deadline = ContinuousClock.now + .seconds(bootTimeoutSecs)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: paths.socket.path) {
                break
            }
            // Check if child exited early (boot failure)
            if !process.isRunning {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        guard FileManager.default.fileExists(atPath: paths.socket.path) else {
            // Read child stderr to surface the real error
            let stderrData = stderrPipe.fileHandleForReading.availableData
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !process.isRunning && !stderrStr.isEmpty {
                FileHandle.standardError.write(Data("lumina: session failed to start: \(stderrStr)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("lumina: session failed to start within \(bootTimeout)\n".utf8))
            }
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

    @Flag(name: .long, help: "Force human-readable text output")
    var text = false

    func run() async throws {
        let client = SessionClient()
        do {
            try client.connect(sid: sid)
            try client.send(.shutdown)
            // Verify the server acknowledged the shutdown
            let response = try? client.receive()
            client.disconnect()

            let confirmed: Bool
            if let response = response {
                switch response {
                case .exit: confirmed = true
                default: confirmed = false
                }
            } else {
                // Connection closed — server shut down (success)
                confirmed = true
            }

            let format = resolveOutputFormat(textFlag: text)
            switch format {
            case .json:
                struct StopResult: Encodable { var stopped: String; var confirmed: Bool }
                encodeAndPrint(StopResult(stopped: sid, confirmed: confirmed))
            case .text:
                print("Session '\(sid)' stopped.")
            }
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

    @Option(name: .long, help: "Working directory inside the VM")
    var workdir: String? = nil

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

        // Forward SIGINT/SIGTERM to the guest command via cancel message
        let cleanupSignals = installSignalForwarding(client: client)
        defer { cleanupSignals() }

        // Execute
        let format = resolveOutputFormat(textFlag: text)
        try client.send(.exec(cmd: command, timeout: timeoutSecs, env: parsedEnv, cwd: workdir))

        while true {
            let response = try client.receive()
            switch response {
            case .output(let outputStream, let data):
                switch format {
                case .json:
                    printNDJSONLine(StreamChunk(stream: outputStream.rawValue, data: data))
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
                    printNDJSONLine(ExitChunk(exit_code: Int(code), duration_ms: durationMs))
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

// MARK: - Volume

struct Volume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage persistent volumes",
        subcommands: [VolumeCreate.self, VolumeList.self, VolumeRemove.self, VolumeInspect.self]
    )
}

struct VolumeCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a named volume")

    @Argument(help: "Volume name")
    var name: String

    func run() throws {
        let store = VolumeStore()
        try store.create(name: name)
        print("Volume '\(name)' created.")
    }
}

struct VolumeList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List volumes")

    func run() throws {
        let store = VolumeStore()
        let names = store.list()
        if names.isEmpty {
            print("No volumes.")
        } else {
            for name in names { print(name) }
        }
    }
}

struct VolumeRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a volume")

    @Argument(help: "Volume name")
    var name: String

    func run() throws {
        let store = VolumeStore()
        try store.remove(name: name)
        print("Volume '\(name)' removed.")
    }
}

struct VolumeInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Show volume details")

    @Argument(help: "Volume name")
    var name: String

    func run() throws {
        let store = VolumeStore()
        let info = try store.inspect(name: name)
        struct VolumeInspectOutput: Encodable {
            var name: String
            var size_bytes: UInt64
            var created: String
            var last_used: String
        }
        let output = VolumeInspectOutput(
            name: info.name,
            size_bytes: info.sizeBytes,
            created: ISO8601DateFormatter().string(from: info.created),
            last_used: ISO8601DateFormatter().string(from: info.lastUsed)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(output),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}

// MARK: - Network

struct NetworkCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Run a group of VMs on a shared network",
        subcommands: [NetworkRun.self]
    )
}

struct NetworkRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run VMs from a manifest file")

    @Option(name: .long, help: "Path to network manifest JSON file")
    var file: String

    func run() async throws {
        installSignalHandlers()
        atexit { DiskClone.cleanOrphans() }

        let fileURL = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            FileHandle.standardError.write(Data("lumina: manifest file not found: \(file)\n".utf8))
            throw ExitCode.failure
        }

        let data = try Data(contentsOf: fileURL)
        let manifest: NetworkManifest
        do {
            manifest = try JSONDecoder().decode(NetworkManifest.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("lumina: invalid manifest: \(error)\n".utf8))
            throw ExitCode.failure
        }

        FileHandle.standardError.write(Data("Starting \(manifest.sessions.count) sessions on shared network...\n".utf8))

        try await Lumina.withNetwork("cli") { network in
            for session in manifest.sessions {
                FileHandle.standardError.write(Data("  Booting '\(session.name)' (image: \(session.image ?? "default"))...\n".utf8))
                _ = try await network.session(
                    name: session.name,
                    image: session.image ?? "default"
                )
            }
            FileHandle.standardError.write(Data("All sessions running. Press Ctrl-C to tear down.\n".utf8))

            // Block main thread until signal — dispatchMain() never returns,
            // signal handler triggers exit, withNetwork scope ensures shutdown
            dispatchMain()
        }
    }
}

struct NetworkManifest: Codable {
    let sessions: [NetworkSession]
}

struct NetworkSession: Codable {
    let name: String
    let image: String?
    let volumes: [String]?
}

// Parsing helpers (parseDuration, parseMemory) are in Lumina/Types.swift
