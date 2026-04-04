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

@Test func decodeUnknownType() {
    let data = Data("{\"type\":\"unknown\"}\n".utf8)
    #expect(throws: LuminaError.self) {
        try Protocol.decodeGuest(data)
    }
}
