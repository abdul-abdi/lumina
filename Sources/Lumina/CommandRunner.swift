// Sources/Lumina/CommandRunner.swift
import Foundation
import os
@preconcurrency import Virtualization

enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case waitingForReady
    case ready
    case executing
    case failed
}

final class CommandRunner: @unchecked Sendable {
    private let socketDevice: VZVirtioSocketDevice
    private let queue: DispatchQueue

    // All mutable state protected by `lock`.
    // CommandRunner is @unchecked Sendable because we guarantee thread safety
    // via NSLock rather than actor isolation (blocking I/O precludes actors).
    private let lock = NSLock()
    private var _connection: VZVirtioSocketConnection?
    private var _inputHandle: FileHandle?
    private var _outputHandle: FileHandle?
    private var _state: ConnectionState = .disconnected

    // Read buffer for the buffered line reader. Only accessed from the active
    // read path (exec or execStream) — never concurrent because the state
    // machine prevents overlapping executions.
    private var readBuffer = Data()

    private static let vsockPort: UInt32 = 1024
    private static let maxRetries = 200      // 200 * 100ms = 20s max
    private static let retryInterval: UInt64 = 100_000_000 // 100ms

    var state: ConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    init(socketDevice: VZVirtioSocketDevice, queue: DispatchQueue) {
        self.socketDevice = socketDevice
        self.queue = queue
    }

    // MARK: - Connect

    func connect() async throws(LuminaError) {
        setState(.connecting)

        for _ in 0..<Self.maxRetries {
            do {
                let conn: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { cont in
                    queue.async { [socketDevice] in
                        socketDevice.connect(toPort: Self.vsockPort) { result in
                            switch result {
                            case .success(let connection):
                                cont.resume(returning: connection)
                            case .failure(let error):
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                setConnection(conn)
                break
            } catch {
                try? await Task.sleep(nanoseconds: Self.retryInterval)
            }
        }

        let (connected, input) = getConnectionInfo()

        guard connected, let input else {
            setState(.disconnected)
            throw .connectionFailed
        }

        setState(.waitingForReady)
        let readyData = try readLine(from: input)
        let msg: GuestMessage
        do {
            msg = try LuminaProtocol.decodeGuest(readyData)
        } catch let error as LuminaError {
            setState(.disconnected)
            throw error
        } catch {
            setState(.disconnected)
            throw .protocolError("Failed to decode guest message: \(error)")
        }
        guard msg == .ready else {
            setState(.disconnected)
            throw .protocolError("Expected ready message, got: \(msg)")
        }

        setState(.ready)
    }

    // MARK: - Buffered Exec (returns complete result)

    func exec(command: String, timeout: Int, env: [String: String] = [:]) throws(LuminaError) -> RunResult {
        let (input, _) = try beginExec(command: command, timeout: timeout, env: env)

        var stdout = ""
        var stderr = ""
        let deadline = ContinuousClock.now + .seconds(timeout)

        while ContinuousClock.now < deadline {
            let guestMsg = try readGuestMessage(from: input)

            switch guestMsg {
            case .ready:
                setState(.ready)
                throw .protocolError("Unexpected ready message during execution")
            case .output(let stream, let data):
                switch stream {
                case .stdout: stdout += data
                case .stderr: stderr += data
                }
            case .exit(let code):
                setState(.ready)
                return RunResult(stdout: stdout, stderr: stderr, exitCode: code, wallTime: .zero)
            case .heartbeat:
                continue
            }
        }

        setState(.failed)
        throw .timeout
    }

    // MARK: - Streaming Exec (yields chunks in real time)

    func execStream(
        command: String,
        timeout: Int,
        env: [String: String] = [:]
    ) throws(LuminaError) -> AsyncThrowingStream<OutputChunk, any Error> {
        let (input, _) = try beginExec(command: command, timeout: timeout, env: env)
        let runner = self

        // Cancellation flag — thread-safe via os_unfair_lock (macOS 14+).
        // Set by onTermination when the consumer drops the stream.
        // The read loop checks it after each message. The blocked
        // availableData call unblocks naturally via heartbeats (5s)
        // or VM shutdown closing the connection.
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                cancelled.withLock { $0 = true }
            }

            Task.detached {
                let deadline = ContinuousClock.now + .seconds(timeout)
                do {
                    while ContinuousClock.now < deadline {
                        if cancelled.withLock({ $0 }) {
                            runner.setState(.ready)
                            continuation.finish()
                            return
                        }

                        let guestMsg = try runner.readGuestMessage(from: input)

                        if cancelled.withLock({ $0 }) {
                            runner.setState(.ready)
                            continuation.finish()
                            return
                        }

                        switch guestMsg {
                        case .ready:
                            runner.setState(.ready)
                            continuation.finish(throwing: LuminaError.protocolError(
                                "Unexpected ready message during execution"
                            ))
                            return
                        case .output(let stream, let data):
                            continuation.yield(stream == .stdout ? .stdout(data) : .stderr(data))
                        case .exit(let code):
                            runner.setState(.ready)
                            continuation.yield(.exit(code))
                            continuation.finish()
                            return
                        case .heartbeat:
                            continue
                        }
                    }
                    runner.setState(.failed)
                    continuation.finish(throwing: LuminaError.timeout)
                } catch {
                    runner.setState(.failed)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func setState(_ newState: ConnectionState) {
        lock.lock()
        _state = newState
        lock.unlock()
    }

    /// Store a new vsock connection and create file handles for I/O.
    private func setConnection(_ conn: VZVirtioSocketConnection) {
        let fd = conn.fileDescriptor
        lock.lock()
        _connection = conn
        _inputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        _outputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        lock.unlock()
    }

    /// Read connection state under lock (safe to call from async contexts).
    private func getConnectionInfo() -> (connected: Bool, input: FileHandle?) {
        lock.lock()
        defer { lock.unlock() }
        return (_connection != nil, _inputHandle)
    }

    /// Validate state, transition to executing, send the exec message.
    /// Returns the input/output handles for the caller to read from.
    ///
    /// The check-and-transition is atomic under a single lock acquisition
    /// to prevent TOCTOU races if exec is called concurrently.
    ///
    /// Timeout enforcement is handled on the host side (the deadline loop in
    /// `exec()` / `execStream()`). The guest receives a safety-net timeout at
    /// 2x the host value — loose enough to never race with the host, tight
    /// enough to clean up if the host crashes or the vsock connection drops.
    private func beginExec(
        command: String, timeout: Int, env: [String: String]
    ) throws(LuminaError) -> (input: FileHandle, output: FileHandle) {
        lock.lock()
        guard _state == .ready, let input = _inputHandle, let output = _outputHandle else {
            lock.unlock()
            throw .connectionFailed
        }
        _state = .executing
        readBuffer = Data()
        lock.unlock()

        // Safety net: guest timeout must be well beyond host deadline + heartbeat interval
        // so the host always detects the timeout first. Minimum 30s to handle short timeouts
        // where 2x would still race with the 5s heartbeat cadence.
        let guestTimeout = max(timeout * 3, 30)
        let execMsg = HostMessage.exec(cmd: command, timeout: guestTimeout, env: env)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(execMsg)
        } catch {
            setState(.ready)
            throw .protocolError("Failed to encode host message: \(error)")
        }
        output.write(msgData)

        return (input, output)
    }

    /// Read one newline-delimited message and decode it.
    private func readGuestMessage(from handle: FileHandle) throws(LuminaError) -> GuestMessage {
        let lineData = try readLine(from: handle)
        do {
            return try LuminaProtocol.decodeGuest(lineData)
        } catch let error as LuminaError {
            throw error
        } catch {
            throw .protocolError("Failed to decode guest message: \(error)")
        }
    }

    /// Buffered line reader — reads available data and returns complete
    /// newline-delimited messages.
    ///
    /// Uses `availableData` instead of `readData(ofLength:)` because VZ
    /// vsock file descriptors behave like pipes on macOS: readData(ofLength: N)
    /// blocks until exactly N bytes arrive, rather than returning a partial
    /// read like a POSIX socket. `availableData` correctly returns whatever
    /// bytes are pending without over-blocking.
    private func readLine(from handle: FileHandle) throws(LuminaError) -> Data {
        // Check if there's already a complete line in the buffer
        if let line = extractLine() {
            return line
        }

        // Read more data until we get a complete line
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF — return whatever is in the buffer
                if readBuffer.isEmpty {
                    throw .connectionFailed
                }
                let remaining = readBuffer
                readBuffer = Data()
                return remaining
            }

            readBuffer.append(chunk)

            if readBuffer.count > LuminaProtocol.maxMessageSize {
                readBuffer = Data()
                throw .protocolError("Message exceeds 64KB limit")
            }

            if let line = extractLine() {
                return line
            }
        }
    }

    /// Extract a complete line (including the newline) from readBuffer, or nil.
    private func extractLine() -> Data? {
        guard let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        let lineEnd = readBuffer.index(after: newlineIndex)
        let line = Data(readBuffer[readBuffer.startIndex..<lineEnd])
        readBuffer.removeSubrange(readBuffer.startIndex..<lineEnd)
        return line
    }
}
