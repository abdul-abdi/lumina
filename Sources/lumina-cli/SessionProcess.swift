// Sources/lumina-cli/SessionProcess.swift
import ArgumentParser
import Darwin
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

    @Option(help: "Forward port (host:guest, repeatable)")
    var forward: [String] = []

    @Option(help: "Idle TTL (e.g. 30m, 1h, 0 to disable). Session auto-stops after this long with no client activity and no active execs.")
    var ttl: String = "0"

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

        // Parse --forward early so bad input fails before boot.
        var forwardSpecs: [ForwardSpec] = []
        for spec in forward {
            guard let parsed = parseForwardSpec(spec) else {
                FileHandle.standardError.write(Data("lumina: invalid --forward '\(spec)'. Use host:guest\n".utf8))
                throw ExitCode.failure
            }
            forwardSpecs.append(parsed)
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
            try await vm.boot()
            // Configure network at session boot — one-time cost, all subsequent
            // exec commands have network available at no extra latency.
            try await vm.configureNetwork()
        } catch {
            FileHandle.standardError.write(Data("lumina: session boot failed: \(error)\n".utf8))
            throw ExitCode.failure
        }

        // Set up port forwards. Each forward binds a host TCP listener on
        // 127.0.0.1:hostPort and dials the guest via vsock for every accepted
        // connection. Failures are surfaced to stderr but do not kill the
        // session — individual forwards that fail to bind are skipped.
        let forwarder = PortForwarder(vm: vm)
        for spec in forwardSpecs {
            do {
                try await forwarder.add(hostPort: spec.hostPort, guestPort: spec.guestPort)
                NSLog(
                    "[Lumina.Session] Port forward: 127.0.0.1:%d -> guest:%d",
                    spec.hostPort, spec.guestPort
                )
            } catch {
                FileHandle.standardError.write(Data(
                    "lumina: failed to forward \(spec.hostPort):\(spec.guestPort): \(error)\n".utf8
                ))
            }
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
            await forwarder.teardownAll()
            await vm.shutdown()
            throw ExitCode.failure
        }

        // Start session server. Pass imageName + bootTime so `.status` replies
        // (used by `lumina ps`) reflect this session's actual image and uptime.
        let server = SessionServer(
            socketPath: paths.socket,
            imageName: image,
            bootTime: info.created
        )
        do {
            try server.bind()
        } catch {
            await forwarder.teardownAll()
            await vm.shutdown()
            paths.cleanup()
            throw ExitCode.failure
        }

        // Serve until shutdown. Forwards are torn down BEFORE vm.shutdown
        // so the stop message can still reach the guest over vsock.
        // parseDuration returns a Duration; convert to TimeInterval (Double
        // seconds) for the SessionServer API. `ttl == "0"` → Duration.zero →
        // seconds == 0 → TTL disabled inside SessionServer.
        let idleTTLSeconds: TimeInterval?
        if let d = parseDuration(ttl) {
            let secs = TimeInterval(d.components.seconds)
            idleTTLSeconds = secs > 0 ? secs : nil
        } else {
            idleTTLSeconds = nil
        }
        await server.serve(vm: vm, idleTTL: idleTTLSeconds) { @Sendable in
            await forwarder.teardownAll()
        }

        // Cleanup
        paths.cleanup()
    }
}

// MARK: - PortForwarder

/// One active port forward: a host TCP listener + its vsock dial port on the
/// guest. Owned by `PortForwarder`.
final class ActiveForward: @unchecked Sendable {
    let hostPort: Int
    let guestPort: Int
    let vsockPort: UInt32
    let listenerFd: Int32
    /// Accept loop task — cancelling it stops new connections. Active proxy
    /// tasks spawned by the accept loop are tracked separately so they are
    /// torn down on teardown() too.
    var acceptTask: Task<Void, Never>?
    private let connLock = NSLock()
    private var connFds: Set<Int32> = []

    init(hostPort: Int, guestPort: Int, vsockPort: UInt32, listenerFd: Int32) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.vsockPort = vsockPort
        self.listenerFd = listenerFd
    }

    func track(_ fd: Int32) {
        connLock.withLock { _ = connFds.insert(fd) }
    }

    func untrack(_ fd: Int32) {
        connLock.withLock { _ = connFds.remove(fd) }
    }

    /// Close all tracked connection fds. Forces any blocked read/write in
    /// proxy tasks to return EBADF/EPIPE so they exit cleanly.
    func closeTrackedConnections() {
        let fds = connLock.withLock { () -> [Int32] in
            let copy = Array(connFds)
            connFds.removeAll()
            return copy
        }
        for fd in fds {
            // SHUT_RDWR first makes blocking reads/writes return promptly.
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// Manages the lifecycle of host-side port forwards for a session.
///
/// Each `add(hostPort:guestPort:)` call asks the guest (via CommandRunner) for
/// a vsock port, binds a host TCP listener on 127.0.0.1:hostPort, and spawns
/// an accept loop. Each accepted TCP connection is paired with a fresh vsock
/// dial to the guest, and two background tasks pump bytes bidirectionally.
///
/// `teardownAll()` must be called BEFORE `vm.shutdown()` so the
/// `port_forward_stop` messages reach the guest over vsock.
actor PortForwarder {
    private let vm: VM
    private var forwards: [Int: ActiveForward] = [:]  // keyed by guestPort

    init(vm: VM) {
        self.vm = vm
    }

    /// Add a new forward. Throws if the guest rejects the request or the
    /// host listener cannot be bound.
    func add(hostPort: Int, guestPort: Int) async throws {
        if forwards[guestPort] != nil {
            throw PortForwardError.duplicate(guestPort: guestPort)
        }

        // Ask the guest to listen; it replies with a reverse-channel vsock port.
        let vsockPort = try await vm.requestPortForward(guestPort: guestPort)

        // Bind host TCP listener on loopback.
        let listenerFd: Int32
        do {
            listenerFd = try Self.bindLoopbackListener(port: hostPort)
        } catch {
            // Tell the guest to release its listener; ignore errors on teardown.
            try? await vm.stopPortForward(guestPort: guestPort)
            throw error
        }

        let fwd = ActiveForward(
            hostPort: hostPort,
            guestPort: guestPort,
            vsockPort: UInt32(vsockPort),
            listenerFd: listenerFd
        )
        forwards[guestPort] = fwd

        // Spawn accept loop — runs until the listener fd is closed.
        let vmRef = vm
        fwd.acceptTask = Task.detached {
            await PortForwarder.runAcceptLoop(forward: fwd, vm: vmRef)
        }
    }

    /// Tear down every active forward: close listeners, shut down proxy
    /// connections, and notify the guest. Must be called before vm.shutdown().
    func teardownAll() async {
        let active = Array(forwards.values)
        forwards.removeAll()

        for fwd in active {
            // Stop new connections by closing the listener fd (forces accept
            // to return EBADF and the loop to exit).
            Darwin.close(fwd.listenerFd)
            fwd.acceptTask?.cancel()
            // Close any in-flight proxy connections so their pump tasks exit.
            fwd.closeTrackedConnections()
            // Notify the guest last — best effort, connection may already be
            // torn down if the session is shutting down for another reason.
            try? await vm.stopPortForward(guestPort: fwd.guestPort)
        }
    }

    // MARK: - Private helpers

    /// Bind a TCP socket on 127.0.0.1:port and start listening.
    /// Returns the listener fd on success. Throws on bind/listen failure.
    private static func bindLoopbackListener(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw PortForwardError.bindFailed(port: port, reason: "socket(): \(String(cString: strerror(errno)))")
        }

        // SO_REUSEADDR — lets a previous CLOSE_WAIT connection release the port.
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian // htons
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")     // loopback only (security model)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw PortForwardError.bindFailed(port: port, reason: "bind(): \(reason)")
        }
        if Darwin.listen(fd, 16) != 0 {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw PortForwardError.bindFailed(port: port, reason: "listen(): \(reason)")
        }
        return fd
    }

    /// Accept loop for one active forward. Runs until the listener fd is
    /// closed (accept returns EBADF) or the task is cancelled.
    private static func runAcceptLoop(forward: ActiveForward, vm: VM) async {
        while !Task.isCancelled {
            let clientFd = Darwin.accept(forward.listenerFd, nil, nil)
            if clientFd < 0 {
                // EBADF on close, EINTR on signal — terminate the loop.
                if errno == EBADF || errno == EINVAL { return }
                if errno == EINTR { continue }
                NSLog(
                    "[Lumina.Session] port-forward %d accept failed: %s",
                    forward.hostPort, strerror(errno)
                )
                return
            }

            forward.track(clientFd)

            // Dial the guest on the reverse vsock channel. `connectVsock`
            // returns a dup'd fd the proxy owns — no VZ object crosses the
            // actor boundary. If the dial fails, drop the TCP connection but
            // keep the listener running for subsequent attempts.
            let vsockFd: Int32
            do {
                vsockFd = try await vm.connectVsock(port: forward.vsockPort)
            } catch {
                NSLog(
                    "[Lumina.Session] port-forward %d vsock dial failed: %@",
                    forward.hostPort, String(describing: error)
                )
                forward.untrack(clientFd)
                _ = Darwin.shutdown(clientFd, SHUT_RDWR)
                Darwin.close(clientFd)
                continue
            }
            forward.track(vsockFd)

            // Two-way proxy: one task per direction. When either side closes,
            // both fds are shut down so the other pump returns promptly.
            Task.detached {
                await PortForwarder.proxyBidirectional(
                    tcpFd: clientFd, vsockFd: vsockFd, forward: forward
                )
            }
        }
    }

    /// Pump bytes bidirectionally between a TCP fd and a vsock fd. Returns
    /// when either side closes or errors. Closes both fds on exit.
    private static func proxyBidirectional(
        tcpFd: Int32, vsockFd: Int32, forward: ActiveForward
    ) async {
        // Run both directions in parallel. The first to finish shuts down
        // the other side, so the second pump exits promptly via EOF or
        // EBADF on its next read/write.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                PortForwarder.pumpBytes(from: tcpFd, to: vsockFd)
                // Half-close the write side of the peer so the other direction
                // can still drain its buffered bytes. Darwin.shutdown is a no-op
                // if already closed.
                _ = Darwin.shutdown(vsockFd, SHUT_WR)
                _ = Darwin.shutdown(tcpFd, SHUT_RD)
            }
            group.addTask {
                PortForwarder.pumpBytes(from: vsockFd, to: tcpFd)
                _ = Darwin.shutdown(tcpFd, SHUT_WR)
                _ = Darwin.shutdown(vsockFd, SHUT_RD)
            }
        }
        forward.untrack(tcpFd)
        forward.untrack(vsockFd)
        Darwin.close(tcpFd)
        Darwin.close(vsockFd)
    }

    /// Blocking copy loop. Reads from `src` and writes everything to `dst`
    /// until EOF or error. Nonisolated-safe.
    private static func pumpBytes(from src: Int32, to dst: Int32) {
        let bufferSize = 32 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            var n: ssize_t
            repeat { n = Darwin.read(src, buffer, bufferSize) } while n < 0 && errno == EINTR
            if n <= 0 { return } // 0 = EOF, <0 = error (EBADF on shutdown)

            var offset: Int = 0
            var remaining = Int(n)
            while remaining > 0 {
                var w: ssize_t
                repeat { w = Darwin.write(dst, buffer + offset, remaining) } while w < 0 && errno == EINTR
                if w <= 0 { return } // EPIPE or EBADF — peer closed
                offset += Int(w)
                remaining -= Int(w)
            }
        }
    }
}

enum PortForwardError: Error, CustomStringConvertible {
    case bindFailed(port: Int, reason: String)
    case duplicate(guestPort: Int)

    var description: String {
        switch self {
        case .bindFailed(let port, let reason):
            return "bind on 127.0.0.1:\(port) failed: \(reason)"
        case .duplicate(let port):
            return "guest port \(port) already forwarded"
        }
    }
}
