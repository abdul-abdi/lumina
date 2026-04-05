// Tests/LuminaTests/ProtocolTests.swift
import Foundation
import Testing
@testable import Lumina

// MARK: - Host Message Tests

@Test func encodeExecMessage() throws {
    let msg = HostMessage.exec(cmd: "echo hello", timeout: 30, env: [:])
    let data = try Protocol.encode(msg)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "exec")
    #expect(json["cmd"] as? String == "echo hello")
    #expect(json["timeout"] as? Int == 30)
}

@Test func encodeExecMessageWithEnv() throws {
    let msg = HostMessage.exec(cmd: "env", timeout: 60, env: ["FOO": "bar"])
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let env = json["env"] as? [String: String]
    #expect(env?["FOO"] == "bar")
}

// MARK: - Guest Message Tests

@Test func decodeReadyMessage() throws {
    let data = Data("{\"type\":\"ready\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .ready)
}

@Test func decodeOutputMessage() throws {
    let data = Data("{\"type\":\"output\",\"stream\":\"stdout\",\"data\":\"hello\\n\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .output(stream: .stdout, data: "hello\n"))
}

@Test func decodeStderrMessage() throws {
    let data = Data("{\"type\":\"output\",\"stream\":\"stderr\",\"data\":\"warn\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .output(stream: .stderr, data: "warn"))
}

@Test func decodeExitMessage() throws {
    let data = Data("{\"type\":\"exit\",\"code\":42}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .exit(code: 42))
}

@Test func decodeInvalidJSON() {
    let data = Data("not json\n".utf8)
    #expect(throws: LuminaError.self) {
        try Protocol.decodeGuest(data)
    }
}

@Test func decodeHeartbeatMessage() throws {
    let data = Data("{\"type\":\"heartbeat\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .heartbeat)
}

@Test func decodeUnknownType() {
    let data = Data("{\"type\":\"unknown\"}\n".utf8)
    #expect(throws: LuminaError.self) {
        try Protocol.decodeGuest(data)
    }
}

// MARK: - Upload Protocol Tests

@Test func encodeUploadMessage() throws {
    let msg = HostMessage.upload(path: "/tmp/test.txt", data: "aGVsbG8=", mode: "0644", seq: 0, eof: true)
    let data = try Protocol.encode(msg)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "upload")
    #expect(json["path"] as? String == "/tmp/test.txt")
    #expect(json["data"] as? String == "aGVsbG8=")
    #expect(json["mode"] as? String == "0644")
    #expect(json["seq"] as? Int == 0)
    #expect(json["eof"] as? Bool == true)
}

@Test func encodeUploadMessageChunked() throws {
    let msg = HostMessage.upload(path: "/tmp/big.bin", data: "AAAA", mode: "0755", seq: 3, eof: false)
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["seq"] as? Int == 3)
    #expect(json["eof"] as? Bool == false)
}

@Test func decodeUploadAckMessage() throws {
    let data = Data("{\"type\":\"upload_ack\",\"seq\":5}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .uploadAck(seq: 5))
}

@Test func decodeUploadDoneMessage() throws {
    let data = Data("{\"type\":\"upload_done\",\"path\":\"/tmp/test.txt\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .uploadDone(path: "/tmp/test.txt"))
}

@Test func decodeUploadErrorMessage() throws {
    let data = Data("{\"type\":\"upload_error\",\"path\":\"/tmp/test.txt\",\"error\":\"permission denied\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .uploadError(path: "/tmp/test.txt", error: "permission denied"))
}

// MARK: - Download Protocol Tests

@Test func encodeDownloadReqMessage() throws {
    let msg = HostMessage.downloadReq(path: "/tmp/output.log")
    let data = try Protocol.encode(msg)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "download_req")
    #expect(json["path"] as? String == "/tmp/output.log")
}

@Test func decodeDownloadDataMessage() throws {
    let data = Data("{\"type\":\"download_data\",\"path\":\"/tmp/out\",\"data\":\"aGVsbG8=\",\"seq\":0,\"eof\":true}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .downloadData(path: "/tmp/out", data: "aGVsbG8=", seq: 0, eof: true))
}

@Test func decodeDownloadDataChunked() throws {
    let data = Data("{\"type\":\"download_data\",\"path\":\"/tmp/out\",\"data\":\"AAAA\",\"seq\":2,\"eof\":false}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .downloadData(path: "/tmp/out", data: "AAAA", seq: 2, eof: false))
}

@Test func decodeDownloadErrorMessage() throws {
    let data = Data("{\"type\":\"download_error\",\"path\":\"/tmp/missing\",\"error\":\"no such file\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .downloadError(path: "/tmp/missing", error: "no such file"))
}

// MARK: - Type Default Tests

@Test func fileUploadDefaults() {
    let upload = FileUpload(localPath: URL(fileURLWithPath: "/tmp/test"), remotePath: "/guest/test")
    #expect(upload.mode == "0644")
}

@Test func mountPointDefaults() {
    let mount = MountPoint(hostPath: URL(fileURLWithPath: "/tmp/share"), guestPath: "/mnt/host")
    #expect(mount.readOnly == false)
}

@Test func runOptionsFileTransferDefaults() {
    let opts = RunOptions()
    #expect(opts.uploads.isEmpty)
    #expect(opts.downloads.isEmpty)
    #expect(opts.mounts.isEmpty)
}

@Test func vmOptionsFromRunOptionsWithMounts() {
    let mount = MountPoint(hostPath: URL(fileURLWithPath: "/tmp"), guestPath: "/mnt")
    let runOpts = RunOptions(mounts: [mount])
    let vmOpts = VMOptions(from: runOpts)
    #expect(vmOpts.mounts.count == 1)
    #expect(vmOpts.mounts[0].guestPath == "/mnt")
}
