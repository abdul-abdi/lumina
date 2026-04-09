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
    var memory: UInt64 = 512 * 1024 * 1024

    @Option(help: "Volume mount (name:guest_path, repeatable)")
    var volume: [String] = []

    func run() async throws {
        installSignalHandlers()

        let paths = SessionPaths(sid: sid)

        // Parse volumes into MountPoints by resolving through VolumeStore
        let volumeStore = VolumeStore()
        var mounts: [MountPoint] = []
        for spec in volume {
            guard let colonIndex = spec.firstIndex(of: ":") else { continue }
            let name = String(spec[spec.startIndex..<colonIndex])
            let guestPath = String(spec[spec.index(after: colonIndex)...])
            guard let hostDir = volumeStore.resolve(name: name) else {
                FileHandle.standardError.write(Data("lumina: volume '\(name)' not found\n".utf8))
                throw ExitCode.failure
            }
            mounts.append(MountPoint(hostPath: hostDir, guestPath: guestPath))
        }

        // Boot VM
        let vmOptions = VMOptions(
            memory: memory,
            cpuCount: cpus,
            image: image,
            mounts: mounts
        )
        let vm = VM(options: vmOptions)

        do {
            try await vm.bootResult().get()
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
