// Tests/LuminaTests/NetworkTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func networkIPAssignment() {
    #expect(NetworkSwitch.ipForIndex(0) == "192.168.100.2")
    #expect(NetworkSwitch.ipForIndex(1) == "192.168.100.3")
}

@Test func networkHostsGeneration() {
    let peers: [(name: String, ip: String)] = [
        ("db", "192.168.100.2"),
        ("api", "192.168.100.3"),
    ]
    let hosts = NetworkSwitch.generateHosts(peers: peers)
    #expect(hosts.contains("192.168.100.2 db"))
    #expect(hosts.contains("192.168.100.3 api"))
}

@Test func vmOptionsPrivateNetworkDefault() {
    let opts = VMOptions()
    #expect(opts.privateNetworkFd == nil)
    #expect(opts.networkHosts == nil)
    #expect(opts.networkIP == nil)
}

@Test func vmOptionsFromRunOptionsNetworkDefaults() {
    let runOpts = RunOptions()
    let vmOpts = VMOptions(from: runOpts)
    #expect(vmOpts.privateNetworkFd == nil)
    #expect(vmOpts.networkHosts == nil)
    #expect(vmOpts.networkIP == nil)
}

@Test func initrdPatcherNetworkOverlay() throws {
    // Create a temporary "base initrd" (just some dummy gzip data)
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let initrdURL = tempDir.appendingPathComponent("test-initrd")

    // Create a minimal gzip file as the base initrd
    let baseContent = Data("base-initrd-content".utf8)
    try baseContent.write(to: initrdURL)

    let hosts: [String: String] = ["db": "192.168.100.2", "api": "192.168.100.3"]
    let ip = "192.168.100.2"

    // Should not throw — appends network overlay
    try InitrdPatcher.appendNetworkOverlay(
        initrdURL: initrdURL,
        hosts: hosts,
        ip: ip
    )

    // Verify the file grew (overlay was appended)
    let resultData = try Data(contentsOf: initrdURL)
    #expect(resultData.count > baseContent.count)

    // Verify it starts with original content
    #expect(resultData.prefix(baseContent.count) == baseContent)
}

@Test func networkActorInit() async {
    // Just verify Network can be initialized
    let network = Network(name: "test")
    await network.shutdown()
}
