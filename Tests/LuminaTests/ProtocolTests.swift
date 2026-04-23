// Tests/LuminaTests/ProtocolTests.swift
import Foundation
import Testing
@testable import Lumina

// MARK: - Host Message Tests

@Test func encodeExecMessage() throws {
    let msg = HostMessage.exec(id: "test-1", cmd: "echo hello", timeout: 30, env: [:])
    let data = try Protocol.encode(msg)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "exec")
    #expect(json["id"] as? String == "test-1")
    #expect(json["cmd"] as? String == "echo hello")
    #expect(json["timeout"] as? Int == 30)
}

@Test func encodeExecMessageWithEnv() throws {
    let msg = HostMessage.exec(id: "test-2", cmd: "env", timeout: 60, env: ["FOO": "bar"])
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["id"] as? String == "test-2")
    let env = json["env"] as? [String: String]
    #expect(env?["FOO"] == "bar")
}

@Test func encodeExecMessageWithCwd() throws {
    let msg = HostMessage.exec(id: "cwd-1", cmd: "pwd", timeout: 30, env: [:], cwd: "/code")
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "exec")
    #expect(json["cwd"] as? String == "/code")
}

@Test func encodeExecMessageWithoutCwd() throws {
    let msg = HostMessage.exec(id: "cwd-2", cmd: "pwd", timeout: 30, env: [:], cwd: nil)
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "exec")
    #expect(json["cwd"] == nil)
}

// MARK: - Guest Message Tests

@Test func decodeReadyMessage() throws {
    let data = Data("{\"type\":\"ready\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .ready)
}

@Test func decodeOutputMessage() throws {
    let data = Data("{\"type\":\"output\",\"id\":\"abc\",\"stream\":\"stdout\",\"data\":\"hello\\n\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .output(id: "abc", stream: .stdout, data: "hello\n"))
}

@Test func decodeStderrMessage() throws {
    let data = Data("{\"type\":\"output\",\"id\":\"abc\",\"stream\":\"stderr\",\"data\":\"warn\"}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .output(id: "abc", stream: .stderr, data: "warn"))
}

@Test func decodeExitMessage() throws {
    let data = Data("{\"type\":\"exit\",\"id\":\"abc\",\"code\":42}\n".utf8)
    let msg = try Protocol.decodeGuest(data)
    #expect(msg == .exit(id: "abc", code: 42))
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

// MARK: - Cancel Protocol Tests

@Test func encodeCancelMessage() throws {
    let msg = HostMessage.cancel(id: nil, signal: 15, gracePeriod: 5)
    let data = try Protocol.encode(msg)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "cancel")
    #expect(json["signal"] as? Int == 15)
    #expect(json["grace_period"] as? Int == 5)
    #expect(json["id"] == nil)  // No id when cancelling all
}

@Test func encodeCancelSIGKILL() throws {
    let msg = HostMessage.cancel(id: nil, signal: 9, gracePeriod: 0)
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["signal"] as? Int == 9)
    #expect(json["grace_period"] as? Int == 0)
}

@Test func encodeCancelWithID() throws {
    let msg = HostMessage.cancel(id: "exec-123", signal: 15, gracePeriod: 3)
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "cancel")
    #expect(json["id"] as? String == "exec-123")
    #expect(json["signal"] as? Int == 15)
}

// MARK: - Binary Output Protocol Tests

@Test func decodeBinaryOutputMessage() throws {
    // Guest emits base64-encoded bytes for non-UTF-8 output
    let rawBytes = Data([0xFF, 0xFE, 0x00, 0x01])
    let encoded = rawBytes.base64EncodedString()
    let json = "{\"type\":\"output\",\"id\":\"exec-1\",\"stream\":\"stdout\",\"data\":\"\(encoded)\",\"encoding\":\"base64\"}\n"
    let msg = try Protocol.decodeGuest(Data(json.utf8))
    if case .outputBinary(let id, let stream, let bytes) = msg {
        #expect(id == "exec-1")
        #expect(stream == .stdout)
        #expect(bytes == rawBytes)
    } else {
        Issue.record("Expected .outputBinary, got \(msg)")
    }
}

@Test func decodeBinaryOutputMessageStderr() throws {
    let rawBytes = Data([0xAB, 0xCD, 0xEF])
    let encoded = rawBytes.base64EncodedString()
    let json = "{\"type\":\"output\",\"id\":\"exec-2\",\"stream\":\"stderr\",\"data\":\"\(encoded)\",\"encoding\":\"base64\"}\n"
    let msg = try Protocol.decodeGuest(Data(json.utf8))
    if case .outputBinary(let id, let stream, let bytes) = msg {
        #expect(id == "exec-2")
        #expect(stream == .stderr)
        #expect(bytes == rawBytes)
    } else {
        Issue.record("Expected .outputBinary, got \(msg)")
    }
}

@Test func decodeTextOutputMessageBackwardCompat() throws {
    // Old guests never set "encoding" → must still decode as .output (text)
    let json = "{\"type\":\"output\",\"id\":\"exec-1\",\"stream\":\"stdout\",\"data\":\"hello world\"}\n"
    let msg = try Protocol.decodeGuest(Data(json.utf8))
    #expect(msg == .output(id: "exec-1", stream: .stdout, data: "hello world"))
}

@Test func decodeMalformedBase64OutputMessage() throws {
    // Invalid base64 in a message with encoding:base64 should throw
    let json = "{\"type\":\"output\",\"id\":\"exec-1\",\"stream\":\"stdout\",\"data\":\"not-valid-base64!!!\",\"encoding\":\"base64\"}\n"
    #expect(throws: LuminaError.self) {
        _ = try Protocol.decodeGuest(Data(json.utf8))
    }
}

// MARK: - Stdin Protocol Tests

@Test func encodeStdinMessage() throws {
    let msg = HostMessage.stdin(id: "exec-1", data: "hello world\n")
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "stdin")
    #expect(json["id"] as? String == "exec-1")
    #expect(json["data"] as? String == "hello world\n")
}

@Test func encodeStdinCloseMessage() throws {
    let msg = HostMessage.stdinClose(id: "exec-1")
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "stdin_close")
    #expect(json["id"] as? String == "exec-1")
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

// MARK: - PTY Message Tests

@Test func encodePtyExecMessage() throws {
    let msg = HostMessage.ptyExec(id: "pty-1", cmd: "claude", timeout: 0, env: [:], cols: 120, rows: 40)
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "pty_exec")
    #expect(json["id"] as? String == "pty-1")
    #expect(json["cmd"] as? String == "claude")
    #expect(json["cols"] as? Int == 120)
    #expect(json["rows"] as? Int == 40)
}

@Test func encodePtyInputMessage() throws {
    let msg = HostMessage.ptyInput(id: "pty-1", data: "aGVsbG8=")
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "pty_input")
    #expect(json["id"] as? String == "pty-1")
    #expect(json["data"] as? String == "aGVsbG8=")
}

@Test func encodeWindowResizeMessage() throws {
    let msg = HostMessage.windowResize(id: "pty-1", cols: 200, rows: 50)
    let data = try Protocol.encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "window_resize")
    #expect(json["cols"] as? Int == 200)
    #expect(json["rows"] as? Int == 50)
}

@Test func decodePtyOutputMessage() throws {
    let raw = Data("{\"type\":\"pty_output\",\"id\":\"pty-1\",\"data\":\"aGVsbG8=\"}\n".utf8)
    let msg = try Protocol.decodeGuest(raw)
    #expect(msg == .ptyOutput(id: "pty-1", data: "aGVsbG8="))
}

@Test func decodePtyExitMessage() throws {
    // PTY uses the same exit message type as regular exec
    let raw = Data("{\"type\":\"exit\",\"id\":\"pty-1\",\"code\":0}\n".utf8)
    let msg = try Protocol.decodeGuest(raw)
    #expect(msg == .exit(id: "pty-1", code: 0))
}

// MARK: - Port Forward Message Tests

@Test func encodePortForwardStartMessage() throws {
    let msg = HostMessage.portForwardStart(guestPort: 3000)
    let data = try Protocol.encode(msg)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "port_forward_start")
    #expect(json["guest_port"] as? Int == 3000)
}

@Test func encodePortForwardStopMessage() throws {
    let msg = HostMessage.portForwardStop(guestPort: 3000)
    let data = try Protocol.encode(msg)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "port_forward_stop")
    #expect(json["guest_port"] as? Int == 3000)
}

@Test func decodePortForwardReadyMessage() throws {
    let raw = Data("{\"type\":\"port_forward_ready\",\"guest_port\":3000,\"vsock_port\":1025}\n".utf8)
    let msg = try Protocol.decodeGuest(raw)
    #expect(msg == .portForwardReady(guestPort: 3000, vsockPort: 1025))
}

@Test func decodePortForwardReadyMissingFields() {
    let raw = Data("{\"type\":\"port_forward_ready\",\"guest_port\":3000}\n".utf8)
    #expect(throws: LuminaError.self) {
        try Protocol.decodeGuest(raw)
    }
}

@Test func decodePortForwardErrorMessage() throws {
    let raw = Data(#"{"type":"port_forward_error","guest_port":3000,"reason":"already active"}"#.utf8)
    let msg = try Protocol.decodeGuest(raw)
    #expect(msg == .portForwardError(guestPort: 3000, reason: "already active"))
}

@Test func decodePortForwardErrorDefaultsReasonWhenMissing() throws {
    // Guest-side backwards-compat: if a future refactor ever forgets the
    // `reason` field, the host must still be able to route the error to
    // the pending continuation rather than crashing on decode.
    let raw = Data(#"{"type":"port_forward_error","guest_port":3000}"#.utf8)
    let msg = try Protocol.decodeGuest(raw)
    #expect(msg == .portForwardError(guestPort: 3000, reason: "unspecified"))
}

@Test func decodePortForwardErrorMissingPortThrows() {
    let raw = Data(#"{"type":"port_forward_error","reason":"already active"}"#.utf8)
    #expect(throws: LuminaError.self) {
        try Protocol.decodeGuest(raw)
    }
}
