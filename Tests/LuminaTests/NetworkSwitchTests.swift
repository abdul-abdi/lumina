// Tests/LuminaTests/NetworkSwitchTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func networkSwitchCreatePort() throws {
    let sw = NetworkSwitch()
    let port = try sw.createPort()
    #expect(port.vmFd >= 0)
    #expect(port.switchFd >= 0)
    sw.close()
}

@Test func networkSwitchRelayFrames() throws {
    let sw = NetworkSwitch()
    let port1 = try sw.createPort()
    let port2 = try sw.createPort()

    sw.startRelay()

    // Write a frame to port1's vmFd (simulating VM1 sending)
    // Data written to vmFd appears on switchFd, which the relay reads.
    let frame = Data("test ethernet frame".utf8)
    let written = frame.withUnsafeBytes { buf in
        Darwin.write(port1.vmFd, buf.baseAddress!, frame.count)
    }
    #expect(written == frame.count)

    // The relay reads from port1.switchFd and writes to port2.switchFd.
    // Data written to port2.switchFd appears on port2.vmFd.
    usleep(50_000) // 50ms for relay to process

    var readBuf = [UInt8](repeating: 0, count: 1500)
    let flags = fcntl(port2.vmFd, F_GETFL)
    fcntl(port2.vmFd, F_SETFL, flags | O_NONBLOCK)
    let readCount = Darwin.read(port2.vmFd, &readBuf, readBuf.count)

    #expect(readCount == frame.count)
    #expect(Data(readBuf[..<readCount]) == frame)

    sw.close()
}

@Test func networkSwitchIPAssignment() {
    #expect(NetworkSwitch.ipForIndex(0) == "192.168.100.2")
    #expect(NetworkSwitch.ipForIndex(1) == "192.168.100.3")
    #expect(NetworkSwitch.ipForIndex(5) == "192.168.100.7")
}

@Test func networkSwitchHostsGeneration() {
    let peers: [(name: String, ip: String)] = [
        ("db", "192.168.100.2"),
        ("api", "192.168.100.3"),
    ]
    let hosts = NetworkSwitch.generateHosts(peers: peers)
    #expect(hosts.contains("192.168.100.2 db"))
    #expect(hosts.contains("192.168.100.3 api"))
    #expect(hosts.contains("127.0.0.1 localhost"))
}
