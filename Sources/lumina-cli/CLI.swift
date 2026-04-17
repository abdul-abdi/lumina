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
                      Session.self, Exec.self, Cp.self, SessionServe.self,
                      Volume.self, NetworkCmd.self, PoolCmd.self]
    )
}

// MARK: - Run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command in a disposable VM")

    @Argument(help: "Command to run in the VM")
    var command: String

    @Option(name: .long, help: "Image to boot from")
    var image: String = "default"

    @Option(name: .long, help: "Command timeout, excludes ~2s boot time (e.g. 30s, 5m). Env: LUMINA_TIMEOUT")
    var timeout: String = "60s"

    @Option(name: [.short, .long], help: "Environment variable (KEY=VAL, repeatable)")
    var env: [String] = []

    @Option(name: .long, help: "Copy file or directory into VM (local:remote, repeatable)")
    var copy: [String] = []

    @Option(name: .long, help: "Download from VM after command (remote:local, repeatable)")
    var download: [String] = []

    @Option(name: .long, help: "Mount host dir or named volume into VM (path_or_name:guest, repeatable)")
    var volume: [String] = []

    @Option(name: .long, help: "Working directory inside the VM")
    var workdir: String? = nil

    @Flag(name: .long, help: "Run in PTY mode (interactive terminal) — use `exec --pty` against a session")
    var pty: Bool = false

    func run() async throws {
        installSignalHandlers()
        atexit { DiskClone.cleanOrphans() }

        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("lumina: command cannot be empty\n".utf8))
            throw ExitCode.failure
        }

        // PTY on disposable `run` is not supported in v0.6.0. Interactive mode
        // requires a persistent session (Unix-socket IPC + bidirectional
        // streaming), so we redirect users to `session start` + `exec --pty`.
        if pty {
            FileHandle.standardError.write(Data(
                "lumina: --pty on `run` requires a session. Use `lumina session start` then `lumina exec --pty <sid> \"<cmd>\"`.\n".utf8
            ))
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

        // Resolve from env vars with built-in defaults
        let resolvedTimeout = resolveTimeout(flag: timeout, defaultValue: "60s")
        let resolvedMemory = resolveMemory(flag: "1GB")
        let resolvedCpus = resolveCpus(flag: 2)
        let resolvedDiskSize = resolveDiskSize(flag: nil)

        guard let parsedTimeout = parseDuration(resolvedTimeout) else {
            FileHandle.standardError.write(Data("lumina: invalid timeout '\(resolvedTimeout)'. Use e.g. 30s, 5m\n".utf8))
            throw ExitCode.failure
        }

        guard let parsedMemory = parseMemory(resolvedMemory) else {
            FileHandle.standardError.write(Data("lumina: invalid memory '\(resolvedMemory)'. Use e.g. 512MB, 1GB\n".utf8))
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

        // Parse --copy: auto-detect file vs directory from local path
        var parsedUploads: [FileUpload] = []
        var parsedDirUploads: [DirectoryUpload] = []
        for spec in copy {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --copy '\(spec)'. Use local:remote format\n".utf8))
                throw ExitCode.failure
            }
            let localStr = String(spec[spec.startIndex..<colonIndex])
            let remote = String(spec[spec.index(after: colonIndex)...])
            let localURL = URL(fileURLWithPath: localStr)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir) else {
                FileHandle.standardError.write(Data("lumina: not found: \(localStr)\n".utf8))
                throw ExitCode.failure
            }
            if isDir.boolValue {
                parsedDirUploads.append(DirectoryUpload(localPath: localURL, remotePath: remote))
            } else {
                let mode = FileManager.default.isExecutableFile(atPath: localURL.path) ? "0755" : "0644"
                parsedUploads.append(FileUpload(localPath: localURL, remotePath: remote, mode: mode))
            }
        }

        // Parse --download: auto-detected as file vs directory at runtime on guest
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

        // Parse --volume: host path (starts with / or .) = mount, otherwise = named volume
        var parsedMounts: [MountPoint] = []
        let volumeStore = VolumeStore()
        for spec in volume {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --volume '\(spec)'. Use path_or_name:guest_path\n".utf8))
                throw ExitCode.failure
            }
            let left = String(spec[spec.startIndex..<colonIndex])
            let guestPath = String(spec[spec.index(after: colonIndex)...])

            if left.hasPrefix("/") || left.hasPrefix(".") {
                // Host directory mount
                let hostURL = URL(fileURLWithPath: left)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir), isDir.boolValue else {
                    FileHandle.standardError.write(Data("lumina: not a directory: \(left)\n".utf8))
                    throw ExitCode.failure
                }
                parsedMounts.append(MountPoint(hostPath: hostURL, guestPath: guestPath))
            } else {
                // Named volume
                guard let hostDir = volumeStore.resolve(name: left) else {
                    FileHandle.standardError.write(Data("lumina: volume '\(left)' not found\n".utf8))
                    throw ExitCode.failure
                }
                volumeStore.touch(name: left)
                parsedMounts.append(MountPoint(hostPath: hostDir, guestPath: guestPath))
            }
        }

        var parsedDiskSize: UInt64? = nil
        if let ds = resolvedDiskSize {
            guard let size = parseMemory(ds) else {
                FileHandle.standardError.write(Data("lumina: invalid disk-size '\(ds)'. Use e.g. 2GB, 4GB\n".utf8))
                throw ExitCode.failure
            }
            parsedDiskSize = size
        }

        let options = RunOptions(
            timeout: parsedTimeout,
            memory: parsedMemory,
            cpuCount: resolvedCpus,
            image: image,
            env: parsedEnv,
            uploads: parsedUploads,
            downloads: parsedDownloads,
            directoryUploads: parsedDirUploads,
            mounts: parsedMounts,
            workingDirectory: workdir,
            diskSize: parsedDiskSize,
            stdin: resolveStdin()
        )

        let format = resolveOutputFormat()
        let shouldStream = resolveStreaming()

        if shouldUseStreaming(format: format, streaming: shouldStream) {
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
                // Prefer raw bytes when available (binary output); fall back to lossy UTF-8 string
                if let bytes = result.stdoutBytes {
                    FileHandle.standardOutput.write(bytes)
                } else {
                    print(result.stdout, terminator: "")
                }
                if let bytes = result.stderrBytes {
                    FileHandle.standardError.write(bytes)
                } else if !result.stderr.isEmpty {
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
                    case .stdoutBytes(let bytes):
                        // Binary stdout: write raw bytes to stdout fd directly (bypasses print buffering)
                        FileHandle.standardOutput.write(bytes)
                    case .stderrBytes(let bytes):
                        FileHandle.standardError.write(bytes)
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
                    case .stdoutBytes(let bytes):
                        FileHandle.standardOutput.write(bytes)
                    case .stderrBytes(let bytes):
                        FileHandle.standardError.write(bytes)
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
    /// Base64-encoded raw stdout bytes. Set only when stdout contained non-UTF-8 data.
    /// When set, `stdout` is a lossy UTF-8 conversion; this field is byte-exact.
    var stdout_bytes: String?
    var stderr_bytes: String?
    var exit_code: Int?
    var error: String?
    var duration_ms: Int
    // v0.6.0: partial data on error
    var partial_stdout: String?
    var partial_stderr: String?
}

private func printResultJSON(_ result: RunResult, durationMs: Int) {
    let r = ResultJSON(
        stdout: result.stdout,
        stderr: result.stderr,
        stdout_bytes: result.stdoutBytes.map { $0.base64EncodedString() },
        stderr_bytes: result.stderrBytes.map { $0.base64EncodedString() },
        exit_code: Int(result.exitCode),
        duration_ms: durationMs
    )
    encodeAndPrint(r)
}

private func printErrorJSON(
    _ error: any Error,
    durationMs: Int,
    friendly: Bool = false,
    errorState: String? = nil,
    partialStdout: String? = nil,
    partialStderr: String? = nil
) {
    let msg = friendly ? friendlyError(error) : String(describing: error)
    var r = ResultJSON(error: msg, duration_ms: durationMs)
    if let state = errorState {
        r.error = state
    }
    if let ps = partialStdout { r.partial_stdout = ps }
    if let pe = partialStderr { r.partial_stderr = pe }
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
        let format = resolveOutputFormat()
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(names),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .text:
            if names.isEmpty {
                print("No images found. Run 'lumina pull' first.")
            } else {
                for name in names { print(name) }
            }
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

    @Flag(name: .long, help: "Enable Rosetta for x86_64 binary translation (stored in image metadata)")
    var rosetta = false

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
                try await Lumina.createImage(name: name, from: from, command: buildCommands[0], options: opts, rosetta: rosetta)
            } else {
                try await Lumina.createImage(name: name, from: from, commands: buildCommands, options: opts, rosetta: rosetta)
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
            var rosetta: Bool
            var size_bytes: UInt64
            var created: String
        }
        let output = ImageInspectOutput(
            name: info.name,
            base: info.base ?? "none",
            command: info.command ?? "none",
            rosetta: info.rosetta,
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

    @Option(name: .long, help: "Number of CPU cores. Env: LUMINA_CPUS")
    var cpus: Int = 2

    @Option(name: .long, help: "Memory (e.g. 512MB, 1GB). Env: LUMINA_MEMORY")
    var memory: String = "1GB"

    @Option(name: .long, help: "Mount host dir or named volume (path_or_name:guest, repeatable)")
    var volume: [String] = []

    @Option(name: .long, help: "Disk size (e.g. 2GB, 4GB). Grows rootfs beyond image default. Env: LUMINA_DISK_SIZE")
    var diskSize: String? = nil

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

        let resolvedMemory = resolveMemory(flag: memory)
        let resolvedCpus = resolveCpus(flag: cpus)

        guard let parsedMemory = parseMemory(resolvedMemory) else {
            FileHandle.standardError.write(Data("lumina: invalid memory '\(resolvedMemory)'\n".utf8))
            throw ExitCode.failure
        }

        let bootTimeoutSecs = 60 // Hardcoded — if boot takes >60s, something is broken

        // Parse --volume: host path (starts with / or .) forwarded as mount,
        // otherwise resolved as named volume
        var sessionVolumes: [(String, String)] = [] // (left, guestPath) pairs for subprocess
        for spec in volume {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --volume '\(spec)'. Use path_or_name:guest_path\n".utf8))
                throw ExitCode.failure
            }
            let left = String(spec[spec.startIndex..<colonIndex])
            let guestPath = String(spec[spec.index(after: colonIndex)...])

            if left.hasPrefix("/") || left.hasPrefix(".") {
                // Validate host directory exists
                let hostURL = URL(fileURLWithPath: left)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir), isDir.boolValue else {
                    FileHandle.standardError.write(Data("lumina: not a directory: \(left)\n".utf8))
                    throw ExitCode.failure
                }
                sessionVolumes.append((left, guestPath))
            } else {
                // Validate named volume exists
                let volumeStore = VolumeStore()
                guard volumeStore.resolve(name: left) != nil else {
                    FileHandle.standardError.write(Data("lumina: volume '\(left)' not found\n".utf8))
                    throw ExitCode.failure
                }
                sessionVolumes.append((left, guestPath))
            }
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
            "--cpus", String(resolvedCpus),
            "--memory", String(parsedMemory),
        ]
        for (left, guestPath) in sessionVolumes {
            process.arguments! += ["--volume", "\(left):\(guestPath)"]
        }
        if let ds = resolveDiskSize(flag: diskSize) {
            process.arguments! += ["--disk-size", ds]
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
                FileHandle.standardError.write(Data("lumina: session failed to start within 60s\n".utf8))
            }
            throw ExitCode.failure
        }

        // Output session ID
        let format = resolveOutputFormat()
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
        let sid = parseSID(self.sid)
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

            let format = resolveOutputFormat()
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

    func run() throws {
        let sessions = SessionPaths.listAll()
        let format = resolveOutputFormat()
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

    @Option(name: .long, help: "Timeout (e.g. 30s, 5m). Env: LUMINA_TIMEOUT")
    var timeout: String = "60s"

    @Option(name: [.short, .long], help: "Environment variable (KEY=VAL, repeatable)")
    var env: [String] = []

    @Option(name: .long, help: "Working directory inside the VM")
    var workdir: String? = nil

    @Flag(name: .long, help: "Run in PTY mode (interactive terminal)")
    var pty: Bool = false

    func run() async throws {
        let sid = parseSID(self.sid)
        let resolvedTimeout = resolveTimeout(flag: timeout, defaultValue: "60s")
        guard let parsedTimeout = parseDuration(resolvedTimeout) else {
            FileHandle.standardError.write(Data("lumina: invalid timeout '\(resolvedTimeout)'\n".utf8))
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

        // PTY mode: interactive, raw-byte bidirectional streaming.
        // Bypasses the non-PTY output/stdin loops entirely — signal handling,
        // stdin pumping, and output decoding all differ.
        if pty {
            try runPtyExec(
                client: client,
                command: command,
                timeoutSecs: timeoutSecs,
                env: parsedEnv
            )
            return
        }

        // Forward SIGINT/SIGTERM to the guest command via cancel message
        let cleanupSignals = installSignalForwarding(client: client)
        defer { cleanupSignals() }

        // Execute
        let format = resolveOutputFormat()
        try client.send(.exec(cmd: command, timeout: timeoutSecs, env: parsedEnv, cwd: workdir))

        // If stdin is piped, forward it to the session server concurrently.
        // The server routes each stdin chunk to the in-flight exec via StdinChannel.
        // `stdinClose` signals EOF so the guest command sees its stdin close cleanly.
        let stdinTask: Task<Void, Never>?
        if isatty(fileno(stdin)) == 0 {
            let handle = FileHandle.standardInput
            stdinTask = Task.detached {
                while !Task.isCancelled {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        // EOF — tell the server stdin is done
                        try? client.send(.stdinClose)
                        break
                    }
                    let text = String(decoding: chunk, as: UTF8.self)
                    try? client.send(.stdin(data: text))
                }
            }
        } else {
            stdinTask = nil
        }
        defer { stdinTask?.cancel() }

        // Output routing: v0.6.0 unifies JSON output for exec with run (single envelope).
        // Legacy NDJSON streaming is preserved behind LUMINA_OUTPUT=ndjson.
        let legacyNDJSON = useLegacyExecOutput()
        let start = ContinuousClock.now

        if format == .json && !legacyNDJSON {
            // Unified envelope: buffer output, emit single JSON object (matches `run`)
            var stdoutBuf = ""
            var stderrBuf = ""

            while true {
                let response: SessionResponse
                do {
                    response = try client.receive()
                } catch {
                    stdinTask?.cancel()
                    let ms = millisSince(start)
                    printErrorJSON(
                        error,
                        durationMs: ms,
                        friendly: true,
                        errorState: "session_disconnected",
                        partialStdout: stdoutBuf,
                        partialStderr: stderrBuf
                    )
                    throw ExitCode.failure
                }

                switch response {
                case .output(let outputStream, let data):
                    if outputStream == .stdout { stdoutBuf += data } else { stderrBuf += data }
                case .outputBytes(let outputStream, let base64):
                    guard let rawBytes = Data(base64Encoded: base64) else {
                        stderrBuf += "lumina: malformed base64 in outputBytes\n"
                        continue
                    }
                    let text = String(decoding: rawBytes, as: UTF8.self)
                    if outputStream == .stdout { stdoutBuf += text } else { stderrBuf += text }
                case .exit(let code, let durationMs):
                    stdinTask?.cancel()
                    let r = ResultJSON(
                        stdout: stdoutBuf,
                        stderr: stderrBuf,
                        exit_code: Int(code),
                        duration_ms: durationMs
                    )
                    encodeAndPrint(r)
                    if code != 0 { throw ExitCode(code) }
                    return
                case .error(let message):
                    stdinTask?.cancel()
                    let ms = millisSince(start)
                    printErrorJSON(
                        LuminaError.sessionFailed(message),
                        durationMs: ms,
                        friendly: true,
                        partialStdout: stdoutBuf,
                        partialStderr: stderrBuf
                    )
                    throw ExitCode.failure
                default:
                    continue
                }
            }
        } else {
            // Legacy NDJSON (LUMINA_OUTPUT=ndjson) or text mode: existing streaming behavior.
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
                    stdinTask?.cancel()
                    switch format {
                    case .json:
                        printNDJSONLine(ExitChunk(exit_code: Int(code), duration_ms: durationMs))
                    case .text:
                        break
                    }
                    if code != 0 { throw ExitCode(code) }
                    return
                case .outputBytes(let outputStream, let base64):
                    guard let rawBytes = Data(base64Encoded: base64) else {
                        FileHandle.standardError.write(Data("lumina: malformed base64 in outputBytes\n".utf8))
                        break
                    }
                    let fd = outputStream == .stdout
                        ? FileHandle.standardOutput
                        : FileHandle.standardError
                    fd.write(rawBytes)
                case .error(let message):
                    stdinTask?.cancel()
                    FileHandle.standardError.write(Data("lumina: \(message)\n".utf8))
                    throw ExitCode.failure
                default:
                    continue
                }
            }
        }
    }

    // MARK: - PTY Exec

    /// Drive an interactive PTY-backed command over a session client.
    ///
    /// Flow:
    ///   1. Require stdin to be a TTY; capture window size.
    ///   2. Switch stdin into raw mode (restored on every exit path).
    ///   3. Install SIGINT/SIGTERM + SIGWINCH dispatch sources.
    ///      - SIGINT is swallowed by the dispatch source; the raw 0x03 byte from
    ///        the terminal is what actually reaches the guest as pty_input.
    ///      - SIGWINCH reads the new size and forwards it as `window_resize`.
    ///   4. Send `pty_exec` with the initial cols/rows.
    ///   5. Pump stdin: read raw bytes from fd 0, forward as base64 `pty_input`.
    ///   6. Consume responses: `pty_output` → raw bytes to stdout, `exit` → done,
    ///      `error` → print to stderr and fail.
    private func runPtyExec(
        client: SessionClient,
        command: String,
        timeoutSecs: Int,
        env: [String: String]
    ) throws {
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data("lumina: --pty requires stdin to be a TTY\n".utf8))
            throw ExitCode.failure
        }
        guard let termSize = getTerminalSize() else {
            FileHandle.standardError.write(Data("lumina: cannot determine terminal size (not a TTY?)\n".utf8))
            throw ExitCode.failure
        }
        guard let originalTermios = enableRawMode() else {
            FileHandle.standardError.write(Data("lumina: failed to set raw mode\n".utf8))
            throw ExitCode.failure
        }
        defer { restoreTerminal(originalTermios) }

        // SIGWINCH forwards resize events; SIGINT/SIGTERM restore the terminal.
        // `client` is Sendable (@unchecked), so capturing it in the @Sendable
        // closure is fine.
        let cleanupPtySignals = installPtySignalHandlers { [client] cols, rows in
            try? client.send(.windowResize(cols: cols, rows: rows))
        }
        defer { cleanupPtySignals() }

        // Send pty_exec request
        try client.send(.ptyExec(
            cmd: command,
            timeout: timeoutSecs,
            env: env,
            cols: termSize.cols,
            rows: termSize.rows
        ))

        // Stdin pump: raw bytes from fd 0 → base64 pty_input frames.
        // `availableData` blocks until data is ready or EOF; on EOF we stop.
        let stdinPtyTask = Task.detached { [client] in
            let handle = FileHandle.standardInput
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF — host-side stdin closed
                let base64 = chunk.base64EncodedString()
                try? client.send(.ptyInput(data: base64))
            }
        }
        defer { stdinPtyTask.cancel() }

        // Output pump: pty_output → raw bytes to stdout, exit → done.
        while true {
            let response: SessionResponse
            do {
                response = try client.receive()
            } catch {
                // Connection dropped mid-session — best effort restore and exit.
                stdinPtyTask.cancel()
                FileHandle.standardError.write(Data("\r\nlumina: session disconnected\r\n".utf8))
                throw ExitCode.failure
            }
            switch response {
            case .ptyOutput(let base64Data):
                if let rawBytes = Data(base64Encoded: base64Data) {
                    FileHandle.standardOutput.write(rawBytes)
                    fflush(stdout)
                }
            case .exit(let code, _):
                stdinPtyTask.cancel()
                if code != 0 { throw ExitCode(code) }
                return
            case .error(let message):
                stdinPtyTask.cancel()
                FileHandle.standardError.write(Data("\r\nlumina: \(message)\r\n".utf8))
                throw ExitCode.failure
            default:
                // Ignore any non-PTY responses (shouldn't occur during a PTY session).
                continue
            }
        }
    }
}

// MARK: - Cp (Session File Transfer)

struct Cp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy files to/from a running session",
        discussion: """
        Copy direction is determined by argument format:
          lumina cp ./local.txt <sid>:/remote.txt    (upload)
          lumina cp <sid>:/remote.txt ./local.txt    (download)
        """
    )

    @Argument(help: "Source (local path or <sid>:/remote/path)")
    var source: String

    @Argument(help: "Destination (local path or <sid>:/remote/path)")
    var destination: String

    func run() async throws {
        let (sid, isUpload, localPath, remotePath) = try parseCpArgs()

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

        if isUpload {
            guard FileManager.default.fileExists(atPath: localPath) else {
                FileHandle.standardError.write(Data("lumina: not found: \(localPath)\n".utf8))
                throw ExitCode.failure
            }
            try client.send(.upload(localPath: localPath, remotePath: remotePath))
            let resp = try client.receive()
            switch resp {
            case .uploadDone:
                break
            case .error(let msg):
                FileHandle.standardError.write(Data("lumina: upload failed: \(msg)\n".utf8))
                throw ExitCode.failure
            default:
                break
            }
        } else {
            try client.send(.download(remotePath: remotePath, localPath: localPath))
            let resp = try client.receive()
            switch resp {
            case .downloadDone:
                break
            case .error(let msg):
                FileHandle.standardError.write(Data("lumina: download failed: \(msg)\n".utf8))
                throw ExitCode.failure
            default:
                break
            }
        }
    }

    /// Parse source/destination to determine session ID, direction, and paths.
    /// Format: one arg is `<sid>:/path`, the other is a local path.
    private func parseCpArgs() throws -> (sid: String, isUpload: Bool, localPath: String, remotePath: String) {
        if let (sid, remote) = parseSessionRef(source) {
            // Source is session ref → download
            return (sid: sid, isUpload: false, localPath: destination, remotePath: remote)
        } else if let (sid, remote) = parseSessionRef(destination) {
            // Destination is session ref → upload
            return (sid: sid, isUpload: true, localPath: source, remotePath: remote)
        } else {
            FileHandle.standardError.write(Data("lumina: one argument must be <sid>:/path (e.g. lumina cp ./file ABC123:/remote)\n".utf8))
            throw ExitCode.failure
        }
    }

    /// Try to parse a string as `<session-id>:/path`. Session IDs are UUIDs (36 chars).
    private func parseSessionRef(_ arg: String) -> (sid: String, path: String)? {
        guard let colonIndex = arg.firstIndex(of: ":") else { return nil }
        let candidate = String(arg[arg.startIndex..<colonIndex])
        let path = String(arg[arg.index(after: colonIndex)...])
        // Session IDs are full UUIDs — validate the format exactly
        guard UUID(uuidString: candidate) != nil, path.hasPrefix("/") else { return nil }
        return (sid: candidate, path: path)
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
        let format = resolveOutputFormat()
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(names),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .text:
            if names.isEmpty {
                print("No volumes.")
            } else {
                for name in names { print(name) }
            }
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

    @Argument(help: "Path to network manifest JSON file")
    var file: String

    @Option(name: .long, help: "Maximum run time (e.g. 30s, 5m, 2h). Exits cleanly on timeout. Default: run until signal.")
    var timeout: String = ""

    func run() async throws {
        // NOTE: sigaction-based installSignalHandlers() is the fallback for other
        // CLI commands, but dispatchMain()'s signal path does not reliably invoke
        // it for cleanup — the sigaction handler calls arbitrary Swift/Foundation
        // code which is not async-signal-safe, so the cleanup it attempts is
        // unreliable. We use DispatchSource.makeSignalSource instead: the handler
        // runs on a normal dispatch queue where calling Swift is safe.
        //
        // Ignore the default disposition so the dispatch source receives the
        // signal instead of the process being terminated before cleanup runs.
        Foundation.signal(SIGINT, SIG_IGN)
        Foundation.signal(SIGTERM, SIG_IGN)

        let signalQueue = DispatchQueue(label: "com.lumina.network-run.signals")
        let myPid = "\(ProcessInfo.processInfo.processIdentifier)"
        let sources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler {
                // Clean up COW clones this process owns (matching our PID),
                // then exit with the conventional 128+signal status. Running
                // on a dispatch queue so Swift calls are safe.
                //
                // DiskClone.cleanOrphans() only removes clones whose PID is
                // DEAD — it won't remove our own because we're still alive.
                // So we scan runs/ ourselves and remove entries whose .pid
                // file matches our current PID.
                let runsDir = DiskClone.defaultRunsDir
                if let entries = try? FileManager.default.contentsOfDirectory(
                    at: runsDir, includingPropertiesForKeys: nil
                ) {
                    for entry in entries {
                        let pidFile = entry.appendingPathComponent(".pid")
                        guard let content = try? String(contentsOf: pidFile, encoding: .utf8) else {
                            continue
                        }
                        if content.trimmingCharacters(in: .whitespacesAndNewlines) == myPid {
                            try? FileManager.default.removeItem(at: entry)
                        }
                    }
                }
                Darwin.exit(128 + sig)
            }
            src.resume()
            return src
        }
        // Retain the sources for the lifetime of dispatchMain().
        // The event handlers capture them via closure, but keep an explicit
        // reference so a compiler pass won't strip them.
        _ = sources

        // Also register an atexit for normal (non-signal) exit paths.
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
            FileHandle.standardError.write(Data("lumina: invalid manifest: \(error.localizedDescription)\nExpected format: {\"sessions\": [{\"name\": \"vm-name\", \"image\": \"default\"}]}\n".utf8))
            throw ExitCode.failure
        }

        let timeoutDuration: Duration?
        if !timeout.isEmpty {
            guard let parsed = parseDuration(timeout) else {
                FileHandle.standardError.write(Data("lumina: invalid timeout '\(timeout)'. Use e.g. 30s, 5m\n".utf8))
                throw ExitCode.failure
            }
            timeoutDuration = parsed
        } else {
            timeoutDuration = nil
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

            // Block the async task until a signal terminates the process via
            // Darwin.exit() in the DispatchSource handler. `dispatchMain()`
            // does not behave correctly when called from within an async
            // context — it either returns early or fails to take over the
            // main thread — which was the root cause of COW clones leaking
            // on SIGTERM: the withNetwork closure would exit, its `defer`s
            // would run to completion, and the process would exit before
            // the signal handler had a chance to clean its own PID's runs.
            if let td = timeoutDuration {
                try await Task.sleep(for: td)
                FileHandle.standardError.write(Data("Timeout reached. Tearing down sessions...\n".utf8))
            } else {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
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

// MARK: - Pool

struct PoolCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pool",
        abstract: "Run commands across a pre-warmed VM pool",
        subcommands: [PoolRun.self]
    )
}

/// `lumina pool run --size N [--count C] [--concurrency K] "cmd"`
///
/// Boots N VMs, then runs `cmd` C times (default N) using up to K concurrent
/// workers (default N). Prints per-run JSON results to stdout and a summary
/// to stderr. Useful for throughput benchmarking and parallel workloads.
struct PoolRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a command on a pre-warmed VM pool")

    @Argument(help: "Command to run in pooled VMs")
    var command: String

    @Option(name: .long, help: "Number of VMs to pre-warm (default 4)")
    var size: Int = 4

    @Option(name: .long, help: "Total number of runs (default equals pool size)")
    var count: Int? = nil

    @Option(name: .long, help: "Max concurrent runs (default equals pool size)")
    var concurrency: Int? = nil

    @Option(name: .long, help: "Image to boot from")
    var image: String = "default"

    @Option(name: .long, help: "Per-run timeout (e.g. 30s, 2m)")
    var timeout: String = "60s"

    @Option(name: [.short, .long], help: "Environment variable (KEY=VAL, repeatable)")
    var env: [String] = []

    @Option(name: .long, help: "Memory per VM (e.g. 512MB, 1GB)")
    var memory: String = "1GB"

    @Option(name: .long, help: "vCPUs per VM")
    var cpus: Int = 2

    @Option(name: .long, help: "Copy file or directory into each VM before run (local:remote, repeatable)")
    var copy: [String] = []

    @Option(name: .long, help: "Download from VM after each run (remote:local, repeatable). Per-run: each run produces its own download.")
    var download: [String] = []

    @Option(name: .long, help: "Mount host dir or named volume into every VM (path_or_name:guest, repeatable). Applied at pool boot time.")
    var volume: [String] = []

    func run() async throws {
        installSignalHandlers()
        atexit { DiskClone.cleanOrphans() }

        let totalRuns = count ?? size
        let maxConcurrent = concurrency ?? size

        guard let parsedTimeout = parseDuration(timeout) else {
            FileHandle.standardError.write(Data("lumina: invalid timeout: \(timeout)\n".utf8))
            throw ExitCode.failure
        }
        guard let parsedMemory = parseMemory(memory) else {
            FileHandle.standardError.write(Data("lumina: invalid memory: \(memory)\n".utf8))
            throw ExitCode.failure
        }
        var parsedEnv: [String: String] = [:]
        for pair in env {
            guard let eqIndex = pair.firstIndex(of: "=") else {
                FileHandle.standardError.write(Data("lumina: invalid env '\(pair)'. Use KEY=VAL format\n".utf8))
                throw ExitCode.failure
            }
            parsedEnv[String(pair[pair.startIndex..<eqIndex])] = String(pair[pair.index(after: eqIndex)...])
        }

        // Parse --copy: auto-detect file vs directory from local path
        var parsedUploads: [FileUpload] = []
        var parsedDirUploads: [DirectoryUpload] = []
        for spec in copy {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --copy '\(spec)'. Use local:remote format\n".utf8))
                throw ExitCode.failure
            }
            let localStr = String(spec[spec.startIndex..<colonIndex])
            let remote = String(spec[spec.index(after: colonIndex)...])
            let localURL = URL(fileURLWithPath: localStr)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir) else {
                FileHandle.standardError.write(Data("lumina: not found: \(localStr)\n".utf8))
                throw ExitCode.failure
            }
            if isDir.boolValue {
                parsedDirUploads.append(DirectoryUpload(localPath: localURL, remotePath: remote))
            } else {
                let mode = FileManager.default.isExecutableFile(atPath: localURL.path) ? "0755" : "0644"
                parsedUploads.append(FileUpload(localPath: localURL, remotePath: remote, mode: mode))
            }
        }

        // Parse --download: auto-detected as file vs directory at runtime on guest
        var parsedDownloads: [FileDownload] = []
        for spec in download {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --download '\(spec)'. Use remote:local format\n".utf8))
                throw ExitCode.failure
            }
            let remote = String(spec[spec.startIndex..<colonIndex])
            let localStr = String(spec[spec.index(after: colonIndex)...])
            parsedDownloads.append(FileDownload(remotePath: remote, localPath: URL(fileURLWithPath: localStr)))
        }

        // Parse --volume: applied at pool boot time (VM-level config)
        var parsedMounts: [MountPoint] = []
        let volumeStore = VolumeStore()
        for spec in volume {
            guard let colonIndex = spec.firstIndex(of: ":") else {
                FileHandle.standardError.write(Data("lumina: invalid --volume '\(spec)'. Use path_or_name:guest_path\n".utf8))
                throw ExitCode.failure
            }
            let left = String(spec[spec.startIndex..<colonIndex])
            let guestPath = String(spec[spec.index(after: colonIndex)...])
            if left.hasPrefix("/") || left.hasPrefix(".") {
                let hostURL = URL(fileURLWithPath: left)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir), isDir.boolValue else {
                    FileHandle.standardError.write(Data("lumina: not a directory: \(left)\n".utf8))
                    throw ExitCode.failure
                }
                parsedMounts.append(MountPoint(hostPath: hostURL, guestPath: guestPath))
            } else {
                guard let hostDir = volumeStore.resolve(name: left) else {
                    FileHandle.standardError.write(Data("lumina: volume '\(left)' not found\n".utf8))
                    throw ExitCode.failure
                }
                volumeStore.touch(name: left)
                parsedMounts.append(MountPoint(hostPath: hostDir, guestPath: guestPath))
            }
        }

        let opts = VMOptions(memory: parsedMemory, cpuCount: cpus, image: image, mounts: parsedMounts)

        let format = resolveOutputFormat()

        FileHandle.standardError.write(Data("Booting \(size) VMs (image: \(image))...\n".utf8))
        let bootStart = ContinuousClock.now

        let pool = Pool(size: size, options: opts)
        try await pool.boot()

        let bootMs = (ContinuousClock.now - bootStart).totalMilliseconds
        FileHandle.standardError.write(Data("Pool ready in \(bootMs)ms. Running \(totalRuns)×\"\(command)\" (concurrency \(maxConcurrent))...\n".utf8))

        let runStart = ContinuousClock.now

        // Collect (index, result) pairs; print each one as it arrives.
        let cmdCopy = command
        let envCopy = parsedEnv
        let timeoutCopy = parsedTimeout
        let uploadsCopy = parsedUploads
        let dirUploadsCopy = parsedDirUploads
        let downloadsCopy = parsedDownloads
        var collectedResults: [(Int, RunResult)] = []

        await withTaskGroup(of: (Int, RunResult).self) { group in
            var inFlight = 0
            var nextIdx = 0
            // Throttle to maxConcurrent in-flight runs
            while nextIdx < totalRuns || inFlight > 0 {
                while inFlight < maxConcurrent && nextIdx < totalRuns {
                    let idx = nextIdx
                    nextIdx += 1
                    inFlight += 1
                    group.addTask { [pool] in
                        do {
                            let r = try await pool.run(
                                cmdCopy,
                                timeout: timeoutCopy,
                                env: envCopy,
                                uploads: uploadsCopy,
                                directoryUploads: dirUploadsCopy,
                                downloads: downloadsCopy
                            )
                            return (idx, r)
                        } catch {
                            return (idx, RunResult(stdout: "", stderr: String(describing: error), exitCode: 1, wallTime: .zero))
                        }
                    }
                }
                if let (idx, result) = await group.next() {
                    collectedResults.append((idx, result))
                    inFlight -= 1
                    // Print result immediately as it arrives
                    if format == .json {
                        printNDJSONLine(PoolResultJSON(
                            run: idx + 1,
                            exit_code: Int(result.exitCode),
                            stdout: result.stdout,
                            stderr: result.stderr,
                            duration_ms: result.wallTime.totalMilliseconds
                        ))
                    } else {
                        let prefix = "[\(idx + 1)/\(totalRuns)] exit=\(result.exitCode) "
                        FileHandle.standardOutput.write(Data(prefix.utf8))
                        FileHandle.standardOutput.write(Data(result.stdout.utf8))
                    }
                }
            }
        }
        let results = collectedResults.map { $0.1 }

        await pool.shutdown()

        let totalMs = (ContinuousClock.now - runStart).totalMilliseconds
        let successes = results.filter { $0.success }.count
        let avgMs = totalRuns > 0 ? results.map { $0.wallTime.totalMilliseconds }.reduce(0, +) / totalRuns : 0

        FileHandle.standardError.write(Data(
            "Done: \(successes)/\(totalRuns) succeeded, total \(totalMs)ms, avg \(avgMs)ms/run\n".utf8
        ))

        if successes < totalRuns { throw ExitCode.failure }
    }
}

private struct PoolResultJSON: Encodable {
    var run: Int
    var exit_code: Int
    var stdout: String
    var stderr: String
    var duration_ms: Int
}

// Parsing helpers (parseDuration, parseMemory) are in Lumina/Types.swift
