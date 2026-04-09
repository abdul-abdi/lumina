// Tests/LuminaTests/SessionServerTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func serverSocketCreation() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let socketPath = tmpDir.appendingPathComponent("control.sock")
    let server = SessionServer(socketPath: socketPath)
    try server.bind()
    defer { server.close() }

    #expect(FileManager.default.fileExists(atPath: socketPath.path))
}

@Test func serverAcceptsConnection() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let socketPath = tmpDir.appendingPathComponent("control.sock")
    let server = SessionServer(socketPath: socketPath)
    try server.bind()
    defer { server.close() }

    // Connect a client socket
    let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(clientFd >= 0)
    defer { close(clientFd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            pathBytes.withUnsafeBufferPointer { src in
                let count = min(src.count, 104)
                dest.update(from: src.baseAddress!, count: count)
                return count
            }
        }
        _ = bound
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(clientFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(connectResult == 0)
}
