// Tests/LuminaTests/TypesTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func runOptionsDefaults() {
    let opts = RunOptions.default
    #expect(opts.timeout == .seconds(60))
    #expect(opts.memory == 512 * 1024 * 1024)
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
