// Sources/Lumina/NetworkSwitch.swift
import Foundation

/// A port on the virtual switch — one end for the VM, one for the relay.
public struct SwitchPort: Sendable {
    /// File descriptor given to VZFileHandleNetworkDeviceAttachment (VM side)
    public let vmFd: Int32
    /// File descriptor owned by NetworkSwitch (relay side)
    public let switchFd: Int32
}

/// Userspace ethernet frame relay using SOCK_DGRAM socketpairs.
/// VZFileHandleNetworkDeviceAttachment requires datagram sockets because
/// VZ writes complete Ethernet frames as individual datagrams.
public final class NetworkSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [SwitchPort] = []
    private var relayThread: Thread?
    private var running = false

    public init() {}

    /// Create a new port on the switch. Returns a pair of fds:
    /// vmFd goes to VZFileHandleNetworkDeviceAttachment,
    /// switchFd is used by the relay loop.
    public func createPort() throws -> SwitchPort {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw LuminaError.sessionFailed("Failed to create SOCK_DGRAM socketpair: \(errno)")
        }
        let port = SwitchPort(vmFd: fds[0], switchFd: fds[1])
        lock.lock()
        ports.append(port)
        lock.unlock()
        return port
    }

    /// Start the relay loop on a background thread.
    /// Reads datagrams from each port's switchFd and writes to all other ports.
    public func startRelay() {
        lock.lock()
        running = true
        lock.unlock()

        let thread = Thread {
            self.relayLoop()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        relayThread = thread
    }

    /// Stop the relay and close all fds.
    public func close() {
        lock.lock()
        running = false
        let currentPorts = ports
        ports = []
        lock.unlock()

        for port in currentPorts {
            Darwin.close(port.vmFd)
            Darwin.close(port.switchFd)
        }
    }

    // MARK: - IP Assignment

    /// Deterministic IP for a session index (0-based).
    /// Range: 192.168.100.2 through 192.168.100.254
    public static func ipForIndex(_ index: Int) -> String {
        "192.168.100.\(index + 2)"
    }

    /// Generate /etc/hosts content for all peers.
    public static func generateHosts(peers: [(name: String, ip: String)]) -> String {
        var lines = ["127.0.0.1 localhost"]
        for peer in peers {
            lines.append("\(peer.ip) \(peer.name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    private func relayLoop() {
        let maxFrame = 1514 // Max ethernet frame size
        var buffer = [UInt8](repeating: 0, count: maxFrame)
        var knownFds: Set<Int32> = []

        while running {
            // Read ports under lock each iteration — picks up newly added ports
            lock.lock()
            let currentPorts = ports
            lock.unlock()

            // Set any new fds to non-blocking
            for port in currentPorts where !knownFds.contains(port.switchFd) {
                let flags = fcntl(port.switchFd, F_GETFL)
                _ = fcntl(port.switchFd, F_SETFL, flags | O_NONBLOCK)
                knownFds.insert(port.switchFd)
            }

            var didWork = false

            for (i, srcPort) in currentPorts.enumerated() {
                let n = Darwin.read(srcPort.switchFd, &buffer, maxFrame)
                if n > 0 {
                    didWork = true
                    // Broadcast to all other ports
                    for (j, dstPort) in currentPorts.enumerated() where j != i {
                        _ = buffer.withUnsafeBufferPointer { buf in
                            Darwin.write(dstPort.switchFd, buf.baseAddress!, n)
                        }
                    }
                }
            }

            if !didWork {
                usleep(1000) // 1ms — avoid busy-spinning
            }
        }
    }
}
