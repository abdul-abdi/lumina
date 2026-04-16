// Sources/lumina-cli/SessionProcess.swift
import ArgumentParser
import Foundation
import Lumina

/// Hidden subcommand spawned by `session start`. Boots a VM, starts a
/// SessionServer on a Unix socket, and runs until shutdown or signal.
struct SessionServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_session-serve",
        abstract: "Internal: serve a session (spawned by session start)",
        shouldDisplay: false // hidden from help
    )

    @Option(help: "Session ID")
    var sid: String

    @Option(help: "Image name")
    var image: String = "default"

    @Option(help: "CPU count")
    var cpus: Int = 2

    @Option(help: "Memory in bytes")
    var memory: UInt64 = 1024 * 1024 * 1024

    @Option(help: "Volume mount (path_or_name:guest_path, repeatable)")
    var volume: [String] = []

    @Option(help: "Disk size in bytes string (e.g. 2GB)")
    var diskSize: String? = nil

    func run() async throws {
        // Ignore SIGPIPE — when a client disconnects mid-exec, writing to
        // the broken socket must not kill the server process.
        signal(SIGPIPE, SIG_IGN)
        installSignalHandlers()

        let paths = SessionPaths(sid: sid)

        // Parse --volume: host path or named volume
        let volumeStore = VolumeStore()
        var mounts: [MountPoint] = []
        for spec in volume {
            guard let colonIndex = spec.firstIndex(of: ":") else { continue }
            let left = String(spec[spec.startIndex..<colonIndex])
            let guestPath = String(spec[spec.index(after: colonIndex)...])

            if left.hasPrefix("/") || left.hasPrefix(".") {
                let hostURL = URL(fileURLWithPath: left)
                mounts.append(MountPoint(hostPath: hostURL, guestPath: guestPath))
            } else {
                guard let hostDir = volumeStore.resolve(name: left) else {
                    FileHandle.standardError.write(Data("lumina: volume '\(left)' not found\n".utf8))
                    throw ExitCode.failure
                }
                mounts.append(MountPoint(hostPath: hostDir, guestPath: guestPath))
            }
        }

        // Auto-detect rosetta from image metadata
        let imageRosetta = ImageStore().readMeta(name: image)?.rosetta ?? false

        // Parse disk size if provided
        var parsedDiskSize: UInt64? = nil
        if let ds = diskSize, let size = parseMemory(ds) {
            parsedDiskSize = size
        }

        // Boot VM
        let vmOptions = VMOptions(
            memory: memory,
            cpuCount: cpus,
            image: image,
            mounts: mounts,
            rosetta: imageRosetta,
            diskSize: parsedDiskSize
        )
        let vm = VM(options: vmOptions)

        do {
            try await vm.bootResult().get()
            // Configure network at session boot — one-time cost, all subsequent
            // exec commands have network available at no extra latency.
            try await vm.configureNetwork()
        } catch {
            FileHandle.standardError.write(Data("lumina: session boot failed: \(error)\n".utf8))
            throw ExitCode.failure
        }

        // Write session metadata
        let info = SessionInfo(
            sid: sid,
            pid: ProcessInfo.processInfo.processIdentifier,
            image: image,
            cpuCount: cpus,
            memory: memory,
            created: Date(),
            status: .running
        )
        do {
            try paths.writeMeta(info)
        } catch {
            await vm.shutdown()
            throw ExitCode.failure
        }

        // Start session server
        let server = SessionServer(socketPath: paths.socket)
        do {
            try server.bind()
        } catch {
            await vm.shutdown()
            paths.cleanup()
            throw ExitCode.failure
        }

        // Serve until shutdown
        await server.serve(vm: vm)

        // Cleanup
        paths.cleanup()
    }
}
