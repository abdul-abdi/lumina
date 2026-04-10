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
