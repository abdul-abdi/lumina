// Tests/LuminaTests/TypesTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func runOptionsDefaults() {
    let opts = RunOptions.default
    #expect(opts.timeout == .seconds(60))
    #expect(opts.memory == 1024 * 1024 * 1024)
    #expect(opts.cpuCount == 2)
    #expect(opts.image == "default")
    #expect(opts.directoryUploads.isEmpty)
    #expect(opts.directoryDownloads.isEmpty)
}

@Test func directoryUploadInit() {
    let upload = DirectoryUpload(localPath: URL(fileURLWithPath: "/tmp/mydir"), remotePath: "/data")
    #expect(upload.localPath.path == "/tmp/mydir")
    #expect(upload.remotePath == "/data")
}

@Test func directoryDownloadInit() {
    let download = DirectoryDownload(remotePath: "/app/dist", localPath: URL(fileURLWithPath: "/tmp/output"))
    #expect(download.remotePath == "/app/dist")
    #expect(download.localPath.path == "/tmp/output")
}

@Test func vmOptionsFromRunOptions() {
    let run = RunOptions(timeout: .seconds(30), memory: 1024 * 1024 * 1024, cpuCount: 4, image: "custom")
    let vm = VMOptions(from: run)
    #expect(vm.memory == 1024 * 1024 * 1024)
    #expect(vm.cpuCount == 4)
    #expect(vm.image == "custom")
}

@Test func runResultSuccess() {
    let success = RunResult(stdout: "ok", stderr: "", exitCode: 0, wallTime: .seconds(1))
    #expect(success.success == true)

    let failure = RunResult(stdout: "", stderr: "err", exitCode: 1, wallTime: .seconds(1))
    #expect(failure.success == false)
}

@Test func outputChunkEquality() {
    #expect(OutputChunk.stdout("hello") == OutputChunk.stdout("hello"))
    #expect(OutputChunk.stdout("hello") != OutputChunk.stderr("hello"))
    #expect(OutputChunk.exit(0) == OutputChunk.exit(0))
    #expect(OutputChunk.exit(0) != OutputChunk.exit(1))
}

@Test func connectionStateEquality() {
    #expect(ConnectionState.disconnected == ConnectionState.disconnected)
    #expect(ConnectionState.ready != ConnectionState.failed)
    #expect(ConnectionState.connecting != ConnectionState.waitingForReady)
    #expect(ConnectionState.failed != ConnectionState.ready)
    #expect(ConnectionState.failed != ConnectionState.disconnected)
    #expect(ConnectionState.failed == ConnectionState.failed)
}

@Test func guestMessageHeartbeatEquality() {
    #expect(GuestMessage.heartbeat == GuestMessage.heartbeat)
    #expect(GuestMessage.heartbeat != GuestMessage.ready)
}

@Test func runOptionsWorkingDirectoryDefaultNil() {
    let opts = RunOptions()
    #expect(opts.workingDirectory == nil)
}

@Test func vmOptionsRosettaDefaultFalse() {
    let opts = VMOptions()
    #expect(opts.rosetta == false)
}

@Test func runOptionsNoRosettaField() {
    // rosetta moved to image metadata — RunOptions no longer has it
    let opts = RunOptions()
    #expect(opts.image == "default")
    #expect(opts.diskSize == nil)
    // Verify no directoryUploads/Downloads by default
    #expect(opts.directoryUploads.isEmpty)
    #expect(opts.directoryDownloads.isEmpty)
}

@Test func luminaErrorDescriptions() {
    #expect(LuminaError.imageNotFound("myimg").errorDescription == "image 'myimg' not found")
    #expect(LuminaError.sessionNotFound("abc-123").errorDescription == "session 'abc-123' not found")
    #expect(LuminaError.sessionDead("abc-123").errorDescription == "session 'abc-123' is no longer running")
    #expect(LuminaError.sessionFailed("disk full").errorDescription == "session failed: disk full")
    #expect(LuminaError.connectionFailed.errorDescription == "failed to connect to guest agent")
    #expect(LuminaError.timeout.errorDescription == "command timed out")
    #expect(LuminaError.protocolError("bad json").errorDescription == "protocol error: bad json")
    #expect(LuminaError.uploadFailed(path: "/tmp/x", reason: "disk full").errorDescription == "upload failed for '/tmp/x': disk full")
    #expect(LuminaError.downloadFailed(path: "/tmp/y", reason: "file not found").errorDescription == "download failed for '/tmp/y': file not found")
}


// MARK: - v0.7.0 M3 — BootableProfile types

@Test func agentImageRef_initWithImageName_storesName() {
    let ref = AgentImageRef(image: "default")
    #expect(ref.image == "default")
}

@Test func agentImageRef_initWithCustomName_storesName() {
    let ref = AgentImageRef(image: "my-image")
    #expect(ref.image == "my-image")
}

@Test func agentImageRef_isSendable() {
    func takeSendable<T: Sendable>(_: T) {}
    takeSendable(AgentImageRef(image: "x"))
}

@Test func vmOptionsAutoDetectsRosettaFromImageMeta() throws {
    // Create a temp image with rosetta metadata
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-types-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("rosetta-img"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let meta = ImageMeta(base: nil, command: nil, created: Date(), rosetta: true)
    try JSONEncoder().encode(meta).write(to: tmpDir.appendingPathComponent("rosetta-img/meta.json"))
    try Data("k".utf8).write(to: tmpDir.appendingPathComponent("rosetta-img/vmlinuz"))
    try Data("r".utf8).write(to: tmpDir.appendingPathComponent("rosetta-img/rootfs.img"))

    // VMOptions.init(from:) reads ImageStore().readMeta — but uses default baseDir
    // So test the readMeta path directly
    let store = ImageStore(baseDir: tmpDir)
    let readMeta = store.readMeta(name: "rosetta-img")
    #expect(readMeta?.rosetta == true)

    // And verify no-meta image returns false
    try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("plain-img"), withIntermediateDirectories: true)
    try Data("k".utf8).write(to: tmpDir.appendingPathComponent("plain-img/vmlinuz"))
    try Data("r".utf8).write(to: tmpDir.appendingPathComponent("plain-img/rootfs.img"))
    let plainMeta = store.readMeta(name: "plain-img")
    #expect(plainMeta == nil) // no meta.json → nil
}
