// Sources/Lumina/CommandRunner.swift
import Foundation
import Virtualization

enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case waitingForReady
    case ready
    case executing
    case finished
}

final class CommandRunner: @unchecked Sendable {
    private let socketDevice: VZVirtioSocketDevice
    private var connection: VZVirtioSocketConnection?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var state: ConnectionState = .disconnected

    private static let vsockPort: UInt32 = 1024
    private static let maxRetries = 40       // 40 * 50ms = 2s max
    private static let retryInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

    init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
    }

    func connect() async throws(LuminaError) {
        state = .connecting

        for _ in 0..<Self.maxRetries {
            do {
                let conn = try await socketDevice.connect(toPort: Self.vsockPort)
                self.connection = conn
                // VZVirtioSocketConnection exposes a raw file descriptor;
                // create FileHandles for reading and writing from it.
                let fd = conn.fileDescriptor
                self.inputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                self.outputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                break
            } catch {
                try? await Task.sleep(nanoseconds: Self.retryInterval)
            }
        }

        guard connection != nil else {
            state = .disconnected
            throw .connectionFailed
        }

        // Wait for ready handshake
        state = .waitingForReady
        guard let input = inputHandle else {
            state = .disconnected
            throw .connectionFailed
        }

        let readyData = try readLine(from: input)
        let msg: GuestMessage
        do {
            msg = try LuminaProtocol.decodeGuest(readyData)
        } catch let error as LuminaError {
            state = .disconnected
            throw error
        } catch {
            state = .disconnected
            throw .protocolError("Failed to decode guest message: \(error)")
        }
        guard msg == .ready else {
            state = .disconnected
            throw .protocolError("Expected ready message, got: \(msg)")
        }

        state = .ready
    }

    func exec(command: String, timeout: Int, env: [String: String] = [:]) throws(LuminaError) -> RunResult {
        guard state == .ready, let input = inputHandle, let output = outputHandle else {
            throw .connectionFailed
        }

        state = .executing

        // Send exec message
        let execMsg = HostMessage.exec(cmd: command, timeout: timeout, env: env)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(execMsg)
        } catch {
            state = .ready
            throw .protocolError("Failed to encode host message: \(error)")
        }
        output.write(msgData)

        // Collect output
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = 1

        let deadline = ContinuousClock.now + .seconds(timeout)

        while ContinuousClock.now < deadline {
            let lineData = try readLine(from: input)
            let guestMsg: GuestMessage
            do {
                guestMsg = try LuminaProtocol.decodeGuest(lineData)
            } catch let error as LuminaError {
                state = .ready
                throw error
            } catch {
                state = .ready
                throw .protocolError("Failed to decode guest message: \(error)")
            }

            switch guestMsg {
            case .ready:
                state = .ready
                throw .protocolError("Unexpected ready message during execution")
            case .output(let stream, let data):
                switch stream {
                case .stdout: stdout += data
                case .stderr: stderr += data
                }
            case .exit(let code):
                exitCode = code
                state = .finished
                return RunResult(stdout: stdout, stderr: stderr, exitCode: exitCode, wallTime: .zero)
            }
        }

        state = .finished
        throw .timeout
    }

    // MARK: - Private

    // Tech debt: readLine is byte-by-byte — acceptable for v0.1 NDJSON but should use buffered reader in v0.2
    private func readLine(from handle: FileHandle) throws(LuminaError) -> Data {
        var buffer = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                if buffer.isEmpty {
                    throw .connectionFailed
                }
                break
            }
            if byte[0] == UInt8(ascii: "\n") {
                buffer.append(byte)
                break
            }
            buffer.append(byte)
            if buffer.count > LuminaProtocol.maxMessageSize {
                throw .protocolError("Message exceeds 64KB limit")
            }
        }
        return buffer
    }
}
