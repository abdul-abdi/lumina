// Tests/LuminaTests/SessionProtocolTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func encodeExecRequest() throws {
    let req = SessionRequest.exec(cmd: "echo hello", timeout: 30, env: ["FOO": "bar"])
    let data = try SessionProtocol.encode(req)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "exec")
    #expect(json["cmd"] as? String == "echo hello")
    #expect(json["timeout"] as? Int == 30)
}

@Test func encodeShutdownRequest() throws {
    let req = SessionRequest.shutdown
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "shutdown")
}

@Test func encodeUploadRequest() throws {
    let req = SessionRequest.upload(localPath: "/host/file.txt", remotePath: "/guest/file.txt")
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "upload")
    #expect(json["local_path"] as? String == "/host/file.txt")
}

@Test func encodeDownloadRequest() throws {
    let req = SessionRequest.download(remotePath: "/guest/out.txt", localPath: "/host/out.txt")
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "download")
}

@Test func decodeOutputResponse() throws {
    let data = Data("{\"type\":\"output\",\"stream\":\"stdout\",\"data\":\"hello\\n\"}\n".utf8)
    let msg = try SessionProtocol.decodeResponse(data)
    #expect(msg == .output(stream: .stdout, data: "hello\n"))
}

@Test func decodeExitResponse() throws {
    let data = Data("{\"type\":\"exit\",\"code\":0,\"duration_ms\":150}\n".utf8)
    let msg = try SessionProtocol.decodeResponse(data)
    #expect(msg == .exit(code: 0, durationMs: 150))
}

@Test func decodeErrorResponse() throws {
    let data = Data("{\"type\":\"error\",\"message\":\"session_dead\"}\n".utf8)
    let msg = try SessionProtocol.decodeResponse(data)
    #expect(msg == .error(message: "session_dead"))
}

@Test func decodeRequestRoundtrip() throws {
    let req = SessionRequest.exec(cmd: "ls -la", timeout: 60, env: [:])
    let data = try SessionProtocol.encode(req)
    let decoded = try SessionProtocol.decodeRequest(data)
    #expect(decoded == req)
}

@Test func encodeCancelRequest() throws {
    let req = SessionRequest.cancel(signal: 15, gracePeriod: 5)
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "cancel")
    #expect(json["signal"] as? Int == 15)
    #expect(json["grace_period"] as? Int == 5)
}

@Test func decodeCancelRequestRoundtrip() throws {
    let req = SessionRequest.cancel(signal: 2, gracePeriod: 10)
    let data = try SessionProtocol.encode(req)
    let decoded = try SessionProtocol.decodeRequest(data)
    #expect(decoded == req)
}

@Test func encodeStdinRequest() throws {
    let req = SessionRequest.stdin(data: "hello world\n")
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "stdin")
    #expect(json["data"] as? String == "hello world\n")
}

@Test func decodeStdinRequestRoundtrip() throws {
    let req = SessionRequest.stdin(data: "test input")
    let data = try SessionProtocol.encode(req)
    let decoded = try SessionProtocol.decodeRequest(data)
    #expect(decoded == req)
}

@Test func encodeStdinCloseRequest() throws {
    let req = SessionRequest.stdinClose
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "stdin_close")
}

@Test func decodeStdinCloseRoundtrip() throws {
    let data = Data("{\"type\":\"stdin_close\"}\n".utf8)
    let decoded = try SessionProtocol.decodeRequest(data)
    #expect(decoded == .stdinClose)
}

@Test func decodeStdinCloseEncodeRoundtrip() throws {
    let req = SessionRequest.stdinClose
    let data = try SessionProtocol.encode(req)
    let decoded = try SessionProtocol.decodeRequest(data)
    #expect(decoded == req)
}

@Test func encodeExecRequestWithCwd() throws {
    let req = SessionRequest.exec(cmd: "pwd", timeout: 30, env: [:], cwd: "/code")
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["cmd"] as? String == "pwd")
    #expect(json["cwd"] as? String == "/code")
}

@Test func decodeExecRequestWithCwd() throws {
    let json = "{\"type\":\"exec\",\"cmd\":\"pwd\",\"timeout\":30,\"env\":{},\"cwd\":\"/code\"}\n"
    let req = try SessionProtocol.decodeRequest(Data(json.utf8))
    #expect(req == .exec(cmd: "pwd", timeout: 30, env: [:], cwd: "/code"))
}

@Test func decodeExecRequestWithoutCwd() throws {
    let json = "{\"type\":\"exec\",\"cmd\":\"pwd\",\"timeout\":30,\"env\":{}}\n"
    let req = try SessionProtocol.decodeRequest(Data(json.utf8))
    #expect(req == .exec(cmd: "pwd", timeout: 30, env: [:], cwd: nil))
}

@Test func encodeOutputBytesResponse() throws {
    let bytes = Data([0x00, 0xFF, 0xDE, 0xAD])
    let response = SessionResponse.outputBytes(stream: .stdout, base64: bytes.base64EncodedString())
    let data = try SessionProtocol.encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "output_bytes")
    #expect(json["stream"] as? String == "stdout")
    #expect(json["base64"] as? String == bytes.base64EncodedString())
}

@Test func decodeOutputBytesResponse() throws {
    let b64 = Data([0x00, 0xFF]).base64EncodedString()
    let raw = Data("{\"base64\":\"\(b64)\",\"stream\":\"stdout\",\"type\":\"output_bytes\"}\n".utf8)
    let msg = try SessionProtocol.decodeResponse(raw)
    #expect(msg == .outputBytes(stream: .stdout, base64: b64))
}

// MARK: - PTY Session Codec Tests

@Test func encodePtyExecRequest() throws {
    let req = SessionRequest.ptyExec(cmd: "claude", timeout: 0, env: [:], cols: 120, rows: 40)
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "pty_exec")
    #expect(json["cmd"] as? String == "claude")
    #expect(json["cols"] as? Int == 120)
    #expect(json["rows"] as? Int == 40)
}

@Test func encodePtyInputRequest() throws {
    let req = SessionRequest.ptyInput(data: "aGVsbG8=")
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "pty_input")
    #expect(json["data"] as? String == "aGVsbG8=")
}

@Test func encodeWindowResizeRequest() throws {
    let req = SessionRequest.windowResize(cols: 200, rows: 50)
    let data = try SessionProtocol.encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "window_resize")
    #expect(json["cols"] as? Int == 200)
}

@Test func decodePtyOutputResponse() throws {
    let data = Data("{\"type\":\"pty_output\",\"data\":\"aGVsbG8=\"}\n".utf8)
    let resp = try SessionProtocol.decodeResponse(data)
    #expect(resp == .ptyOutput(data: "aGVsbG8="))
}

@Test func decodePtyExecRequest() throws {
    let data = Data("{\"type\":\"pty_exec\",\"cmd\":\"claude\",\"timeout\":0,\"env\":{},\"cols\":120,\"rows\":40}\n".utf8)
    let req = try SessionProtocol.decodeRequest(data)
    #expect(req == .ptyExec(cmd: "claude", timeout: 0, env: [:], cols: 120, rows: 40))
}
