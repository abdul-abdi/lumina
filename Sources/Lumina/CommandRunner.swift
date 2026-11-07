// Sources/Lumina/CommandRunner.swift
import Foundation
import os
@preconcurrency import Virtualization

enum ConnectionState: Sendable, Equatable {
    case disconnected
    case ready
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

    // ── Exec handlers: one AsyncStream per in-flight command, keyed by ID ──
    private var execHandlers: [String: AsyncStream<GuestMessage>.Continuation] = [:]

    // ── PTY handlers: separate lock + map (PTY and exec are distinct I/O models) ──
    // PTY has its own lock to avoid contending with exec on high-frequency
    // resize/input traffic. Hickey review: shared locks across independent
    // concerns is accidental complexity.
    private let ptyLock = NSLock()
    private var ptyHandlers: [String: AsyncStream<GuestMessage>.Continuation] = [:]

    // ── Transfer handler: at most ONE transfer at a time ──
    // Upload and download are sequential, ACK-driven protocols — different
    // from the multiplexed exec protocol. They get a dedicated handler slot
    // instead of sharing the exec map. Concurrent transfers are rejected.
    private var transferContinuation: AsyncStream<GuestMessage>.Continuation?

    // ── Network readiness: one-shot continuation for configure_network flow ──
    private var networkContinuation: CheckedContinuation<GuestMessage, Error>?

    // ── Network metrics: latest snapshot from guest ticker ──
    // Updated every time a `network_metrics` frame arrives. Read by
    // exec() at return time so RunResult carries "what was the state when
    // the command finished." nil means no metrics ever arrived (short
    // command beat the ticker's 500ms initial delay, or legacy agent).
    private var _latestNetworkMetrics: NetworkMetricsSummary?

    // ── Late-exit grace window (v0.7.2) ──
    // Audit-flagged correctness fix: a slow command finishing a
    // hair after the timeout watchdog fired could lose its exit
    // code — host returned `timeout`, guest had already returned 0.
    // Agents retrying non-idempotent ops did the work twice with
    // no signal that they had.
    //
    // Fix: `exec()` / `execStream()` use a soft/hard deadline
    // pattern. The watchdog fires SIGTERM at the soft deadline
    // (T+timeout) and wakes the loop, but the loop keeps reading
    // the stream until the hard deadline (soft + grace window).
    // A natural `.exit` during the grace window beats the
    // synthetic timeout — the handler is still registered, so
    // the dispatcher routes the message into the same stream
    // we're still reading.
    //
    // 250 ms picked because the typical guest-side cancel→exit
    // RTT is well under 50 ms; 250 ms covers the 95th-percentile
    // "command was about to exit anyway" race without making
    // genuine timeouts feel sluggish.
    private static let lateExitGraceWindow: Duration = .milliseconds(250)

    /// The guest reports a signal-killed process as a negative code; 128+N is
    /// the shell convention for the same thing.
    private static func isSignalDeath(_ code: Int32) -> Bool {
        code < 0 || code == 128 + SIGTERM || code == 128 + SIGKILL
    }

    // ── Port forward continuations: one per in-flight port_forward_start ──
    // Keyed by guestPort. Throwing so teardown (reset/dispatcher error) can
    // surface `.connectionFailed` to the caller instead of silently succeeding
    // with a bogus vsock port.
    private var portForwardContinuations: [Int: CheckedContinuation<Int, any Error>] = [:]

    private var dispatcherGeneration = 0

    private static let vsockPort: UInt32 = 1024
    private static let maxRetries = 2000     // 2000 * 10ms = 20s max
    private static let retryInterval: UInt64 = 10_000_000  // 10ms — shaves ~10-15ms off cold boot (prev 20ms)

    /// Latest network metrics snapshot seen on this connection. nil when no
    /// metrics have arrived yet (short command + 500ms ticker delay, or
    /// pre-v0.7.1 agent with no ticker). Thread-safe read.
    var latestNetworkMetrics: NetworkMetricsSummary? {
        lock.withLock { _latestNetworkMetrics }
    }

    var state: ConnectionState {
        lock.withLock { _state }
    }

    /// Number of exec commands currently in flight.
    var activeExecCount: Int {
        lock.withLock { execHandlers.count }
    }

    init(socketDevice: VZVirtioSocketDevice, queue: DispatchQueue) {
        self.socketDevice = socketDevice
        self.queue = queue
    }

    // MARK: - Connect

    func connect() async throws(LuminaError) {
        for _ in 0..<Self.maxRetries {
            do {
                let socketBox = UncheckedSendable(socketDevice)
                let connBox: UncheckedSendable<VZVirtioSocketConnection> = try await withCheckedThrowingContinuation { cont in
                    queue.async {
                        socketBox.value.connect(toPort: Self.vsockPort) { result in
                            switch result {
                            case .success(let connection):
                                cont.resume(returning: UncheckedSendable(connection))
                            case .failure(let error):
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                setConnection(connBox.value)
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

        // Wait for the guest agent's "ready" message.
        // This is the only synchronous read — after this, the dispatcher takes over.
        var readBuffer = Data()
        let readyData = try readLine(from: input, buffer: &readBuffer)
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
        guard case .ready(let protocolVersion) = msg else {
            setState(.disconnected)
            throw .protocolError("Expected ready message, got: \(msg)")
        }
        StaleGuestImageWarning.emitIfNeeded(guestProtocolVersion: protocolVersion)

        setState(.ready)
        startDispatcher(initialBuffer: readBuffer)
    }

    // MARK: - Concurrent Exec (returns complete result)

    func exec(
        id: String,
        command: String,
        timeout: Int,
        env: [String: String] = [:],
        cwd: String? = nil,
        afterDispatched: (@Sendable () -> Void)? = nil
    ) async throws(LuminaError) -> RunResult {
        let chunks = try execStream(
            id: id, command: command, timeout: timeout, env: env, cwd: cwd, afterDispatched: afterDispatched
        )
        var stdout = ""
        var stderr = ""
        // Binary accumulators only populated when the guest emits at least one
        // base64-encoded (non-UTF-8) chunk. If every chunk is UTF-8 these stay
        // nil and RunResult.stdoutBytes/stderrBytes are nil.
        var stdoutBytes: Data? = nil
        var stderrBytes: Data? = nil
        do {
            for try await chunk in chunks {
                switch chunk {
                case .stdout(let data):
                    stdout += data
                    stdoutBytes?.append(Data(data.utf8))
                case .stderr(let data):
                    stderr += data
                    stderrBytes?.append(Data(data.utf8))
                // First binary chunk: seed the bytes accumulator with whatever
                // UTF-8 text has been collected so far, so downstream consumers
                // reading stdoutBytes get a byte-exact view of the full stream.
                case .stdoutBytes(let bytes):
                    if stdoutBytes == nil { stdoutBytes = Data(stdout.utf8) }
                    stdoutBytes?.append(bytes)
                    stdout += String(decoding: bytes, as: UTF8.self)
                case .stderrBytes(let bytes):
                    if stderrBytes == nil { stderrBytes = Data(stderr.utf8) }
                    stderrBytes?.append(bytes)
                    stderr += String(decoding: bytes, as: UTF8.self)
                case .exit(let code):
                    return RunResult(
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: code,
                        wallTime: .zero,
                        stdoutBytes: stdoutBytes,
                        stderrBytes: stderrBytes,
                        networkMetrics: latestNetworkMetrics
                    )
                }
            }
        } catch let error as LuminaError {
            throw error
        } catch {
            throw .connectionFailed
        }
        throw .connectionFailed
    }

    // MARK: - Concurrent Streaming Exec (yields chunks in real time)

    func execStream(
        id: String,
        command: String,
        timeout: Int,
        env: [String: String] = [:],
        cwd: String? = nil,
        afterDispatched: (@Sendable () -> Void)? = nil
    ) throws(LuminaError) -> AsyncThrowingStream<OutputChunk, any Error> {
        let msgStream = registerExecHandler(id)

        // If the send throws, the AsyncThrowingStream is never created and
        // onTermination is never registered, so we must explicitly clean up here.
        do throws(LuminaError) {
            guard state == .ready else { throw .connectionFailed }
            try send(.exec(id: id, cmd: command, timeout: max(timeout * 3, 30), env: env, cwd: cwd))
        } catch {
            unregisterExecHandler(id)
            throw error
        }
        afterDispatched?()

        let runner = self
        let execId = id

        return AsyncThrowingStream { continuation in
            // Soft deadline fires the cancel; hard deadline + grace
            // window is when we actually throw timeout. Lets a natural
            // exit racing the watchdog still report its real code.
            let softDeadline = ContinuousClock.now + .seconds(timeout)
            let hardDeadline = softDeadline + Self.lateExitGraceWindow

            let watchdog = Task.detached { [weak runner] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard let runner else { return }
                try? runner.cancel(id: execId, signal: 15, gracePeriod: 5)
                runner.yieldSyntheticHeartbeat(to: execId)
                do { try await Task.sleep(for: Self.lateExitGraceWindow) } catch { return }
                runner.yieldSyntheticHeartbeat(to: execId)
            }

            let task = Task.detached {
                for await msg in msgStream {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if ContinuousClock.now > hardDeadline {
                        // Cancel is idempotent on the guest side.
                        try? runner.cancel(id: execId, signal: 15, gracePeriod: 5)
                        continuation.finish(throwing: LuminaError.timeout)
                        return
                    }
                    switch msg {
                    case .output(_, let stream, let data):
                        continuation.yield(stream == .stdout ? .stdout(data) : .stderr(data))
                    case .outputBinary(_, let stream, let bytes):
                        continuation.yield(stream == .stdout ? .stdoutBytes(bytes) : .stderrBytes(bytes))
                    case .exit(_, let code):
                        // The grace window exists to preserve a command that finished
                        // on its own just after the deadline. An exit past the soft
                        // deadline that reports signal death is not that — it is the
                        // watchdog's own SIGTERM coming back, and reporting it as an
                        // exit code loses the documented `timeout` envelope entirely.
                        if ContinuousClock.now > softDeadline, Self.isSignalDeath(code) {
                            continuation.finish(throwing: LuminaError.timeout)
                            return
                        }
                        continuation.yield(.exit(code))
                        continuation.finish()
                        return
                    default:
                        break
                    }
                }
                continuation.finish(throwing: LuminaError.connectionFailed)
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                watchdog.cancel()
                runner.unregisterExecHandler(execId)
            }
        }
    }

    // MARK: - Stdin

    /// Send stdin data to a running command (text only — binary data should
    /// be transferred via the upload protocol with base64 encoding).
    func sendStdin(id: String, data: String) throws(LuminaError) {
        try send(.stdin(id: id, data: data))
    }

    /// Close the stdin pipe for a running command.
    func closeStdin(id: String) throws(LuminaError) {
        try send(.stdinClose(id: id))
    }

    // MARK: - PTY Exec

    /// Execute a command in a PTY on the guest. Returns an AsyncThrowingStream of PtyChunk.
    /// The caller reads raw terminal output and receives an exit code when the process ends.
    func execPty(
        id: String,
        command: String,
        timeout: Int,
        env: [String: String] = [:],
        cols: Int,
        rows: Int
    ) throws(LuminaError) -> AsyncThrowingStream<PtyChunk, any Error> {
        guard state == .ready else {
            throw .connectionFailed
        }

        let (stream, continuation) = AsyncStream<GuestMessage>.makeStream()
        ptyLock.withLock { ptyHandlers[id] = continuation }
        do {
            try send(.ptyExec(id: id, cmd: command, timeout: timeout, env: env, cols: cols, rows: rows))
        } catch {
            unregisterPtyHandler(id)
            throw error
        }

        // Transform GuestMessage stream into PtyChunk stream
        let runner = self
        let ptyId = id
        return AsyncThrowingStream { cont in
            let task = Task.detached {
                for await guestMsg in stream {
                    switch guestMsg {
                    case .ptyOutput(_, let base64Data):
                        guard let rawBytes = Data(base64Encoded: base64Data) else { continue }
                        cont.yield(.output(rawBytes))
                    case .exit(_, let code):
                        cont.yield(.exit(code))
                        cont.finish()
                        runner.unregisterPtyHandler(ptyId)
                        return
                    default:
                        continue
                    }
                }
                // Stream ended without exit (connection lost)
                cont.finish(throwing: LuminaError.connectionFailed)
                runner.unregisterPtyHandler(ptyId)
            }

            cont.onTermination = { @Sendable _ in
                task.cancel()
                runner.unregisterPtyHandler(ptyId)
            }
        }
    }

    /// Unregister a PTY handler and finish its stream.
    private func unregisterPtyHandler(_ id: String) {
        ptyLock.withLock { ptyHandlers.removeValue(forKey: id) }?.finish()
    }

    /// Send raw input bytes to a running PTY session.
    func sendPtyInput(id: String, data: Data) throws(LuminaError) {
        try send(.ptyInput(id: id, data: data.base64EncodedString()))
    }

    /// Send a window resize event to a running PTY session.
    func sendWindowResize(id: String, cols: Int, rows: Int) throws(LuminaError) {
        try send(.windowResize(id: id, cols: cols, rows: rows))
    }

    // MARK: - Reconnect

    /// Reconnect after a connection drop: tell the guest to kill whatever
    /// the old connection was running, close it, and connect afresh.
    func reconnect() async throws(LuminaError) {
        if let fd = failAll(.disconnected, dropConnection: true) {
            if let data = try? LuminaProtocol.encode(.cancel(id: nil, signal: 9, gracePeriod: 0)) {
                data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
            }
            // Close the fd — this unblocks the dispatcher's readLine (EOF)
            Darwin.close(fd)
        }
        try await connect()
    }

    /// Finish every waiting exec, PTY, transfer, network and port-forward
    /// caller so none hangs on a dead connection. Returns the old fd when
    /// `dropConnection` detached it.
    private func failAll(_ newState: ConnectionState, dropConnection: Bool) -> Int32? {
        var fd: Int32?
        let (execs, transfer, network, forwards) = lock.withLock {
            _state = newState
            if dropConnection {
                dispatcherGeneration += 1
                fd = _connection?.fileDescriptor
                _connection = nil
                _inputHandle = nil
                _outputHandle = nil
            }
            defer {
                execHandlers = [:]
                transferContinuation = nil
                networkContinuation = nil
                portForwardContinuations = [:]
            }
            return (execHandlers, transferContinuation, networkContinuation, portForwardContinuations)
        }
        let ptys = ptyLock.withLock {
            defer { ptyHandlers = [:] }
            return ptyHandlers
        }
        execs.values.forEach { $0.finish() }
        ptys.values.forEach { $0.finish() }
        transfer?.finish()
        network?.resume(throwing: LuminaError.connectionFailed)
        forwards.values.forEach { $0.resume(throwing: LuminaError.connectionFailed) }
        return fd
    }

    // MARK: - Cancel

    /// Send a cancel message to the guest agent.
    /// If id is nil, cancels all running commands.
    func cancel(id: String? = nil, signal: Int32 = 15, gracePeriod: Int = 5) throws(LuminaError) {
        try send(.cancel(id: id, signal: signal, gracePeriod: gracePeriod))
    }

    // MARK: - Network Configuration (host-driven)

    /// Send network configuration to the guest and wait for network_ready.
    /// The guest applies IP/route/DNS synchronously, then polls carrier.
    /// Waiting ensures DNS is in place before any exec command starts.
    /// Returns the guest's self-reported config duration and which gate
    /// fired (`"operstate"`, `"carrier"`, or `"timeout-anyway"` — the
    /// last meaning the route is verified but the carrier poll gave up
    /// waiting). Old agents omit these fields; the decoder defaults
    /// `configMs` to 0 and `stage` to "" in that case.
    func configureNetwork(ip: String, gateway: String, dns: String) async throws(LuminaError) -> (configMs: Int, stage: String) {
        // Register continuation BEFORE sending the message to avoid a race
        // where the guest replies before we're ready to receive. The
        // throwing continuation lets teardown surface as a real error
        // instead of a synthetic `.networkReady(ip:"")` success.
        let reply: GuestMessage
        do {
            reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GuestMessage, Error>) in
                lock.withLock { networkContinuation = cont }
                // Now safe to send — reply routes to cont via the dispatcher.
                do {
                    try send(.configureNetwork(ip: ip, gateway: gateway, dns: dns))
                } catch {
                    // The send failed — unregister and resume so the caller doesn't hang.
                    lock.withLock { networkContinuation = nil }
                    cont.resume(throwing: error)
                }
            }
        } catch let err as LuminaError {
            throw err
        } catch {
            throw .connectionFailed
        }
        if case .networkReady(_, let configMs, let stage, let dnsOk) = reply {
            // The whole point of awaiting network_ready is that DNS resolves
            // before the caller's first command. The guest now reads
            // resolv.conf back rather than trusting its own write, so when it
            // says DNS is broken, say so instead of letting `curl` be the
            // messenger.
            if !dnsOk {
                FileHandle.standardError.write(Data(
                    "[lumina] warning: the guest could not write /etc/resolv.conf; name resolution will fail. Traffic to literal IPs still works.\n".utf8
                ))
            }
            return (configMs: configMs, stage: stage)
        }
        return (configMs: 0, stage: "")
    }

    // MARK: - Port Forwarding (host-driven)

    /// Ask the guest agent to open a TCP listener on `guestPort` and allocate a
    /// reverse-channel vsock port. Suspends until the guest responds with
    /// `port_forward_ready` carrying the vsock port, or until the connection
    /// tears down (in which case the continuation is resumed with
    /// `.connectionFailed`).
    func requestPortForward(guestPort: Int) async throws(LuminaError) -> Int {
        // Register continuation BEFORE sending so a fast guest reply cannot
        // arrive before the map entry exists. All lock operations happen inside
        // this synchronous closure — NSLock is async-unavailable in Swift 6.
        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, any Error>) in
                let failure: LuminaError? = lock.withLock {
                    guard _state == .ready else { return .connectionFailed }
                    guard portForwardContinuations[guestPort] == nil else {
                        return .protocolError("port_forward_start already in flight for guest port \(guestPort)")
                    }
                    portForwardContinuations[guestPort] = cont
                    return nil
                }
                if let failure {
                    cont.resume(throwing: failure)
                    return
                }

                do {
                    try send(.portForwardStart(guestPort: guestPort))
                } catch {
                    // The send failed — remove entry and resume before
                    // the dispatcher has any chance of finding it.
                    lock.withLock { portForwardContinuations.removeValue(forKey: guestPort) }?
                        .resume(throwing: LuminaError.connectionFailed)
                }
            }
        } catch let luminaError as LuminaError {
            throw luminaError
        } catch {
            throw .connectionFailed
        }
    }

    /// Tell the guest to stop forwarding `guestPort`. Idempotent on the guest.
    func stopPortForward(guestPort: Int) throws(LuminaError) {
        try send(.portForwardStop(guestPort: guestPort))
    }

    // MARK: - File Upload (async, through dispatcher)

    /// Upload a file to the guest via the vsock protocol.
    /// Only one transfer (upload or download) can be active at a time.
    /// Sends base64-encoded chunks with ACK backpressure.
    func upload(_ file: FileUpload) async throws(LuminaError) {
        let stream = try acquireTransferHandler()
        defer { releaseTransferHandler() }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: file.localPath)
        } catch {
            throw .uploadFailed(path: file.remotePath, reason: "Cannot read local file: \(error)")
        }

        // 45KB raw → ~60KB base64 + ~200B JSON envelope = well within 128KB limit.
        let chunkSize = 45 * 1024
        let totalChunks = max(1, (fileData.count + chunkSize - 1) / chunkSize)

        for seq in 0..<totalChunks {
            let start = seq * chunkSize
            let end = min(start + chunkSize, fileData.count)
            let chunk = fileData[start..<end]
            let b64 = chunk.base64EncodedString()
            let isEof = seq == totalChunks - 1

            try send(.upload(path: file.remotePath, data: b64, mode: file.mode, seq: seq, eof: isEof))

            // Wait for ACK (skip heartbeats)
            var gotAck = false
            for await response in stream {
                switch response {
                case .uploadAck(let ackSeq):
                    guard ackSeq == seq else {
                        throw .uploadFailed(path: file.remotePath, reason: "Seq mismatch: expected \(seq), got \(ackSeq)")
                    }
                    gotAck = true
                case .uploadError(_, let errorStr):
                    throw .uploadFailed(path: file.remotePath, reason: errorStr)
                case .heartbeat:
                    continue
                default:
                    throw .protocolError("Expected upload_ack, got: \(response)")
                }
                if gotAck { break }
            }
            // Same shape as download: a finished stream means the connection
            // dropped mid-transfer, not that the chunk was accepted.
            guard gotAck else {
                throw .uploadFailed(
                    path: file.remotePath,
                    reason: "connection closed waiting for ack of chunk \(seq)/\(totalChunks)"
                )
            }
        }

        // Wait for upload_done confirmation
        var done = false
        for await response in stream {
            switch response {
            case .uploadDone:
                done = true
            case .uploadError(_, let errorStr):
                throw .uploadFailed(path: file.remotePath, reason: errorStr)
            case .heartbeat:
                continue
            default:
                throw .protocolError("Expected upload_done, got: \(response)")
            }
            if done { break }
        }
        guard done else {
            throw .uploadFailed(
                path: file.remotePath,
                reason: "connection closed before upload_done; remote file may be incomplete"
            )
        }
    }

    // MARK: - File Download (async, through dispatcher)

    /// Download a file from the guest via the vsock protocol.
    /// Only one transfer (upload or download) can be active at a time.
    func download(_ file: FileDownload) async throws(LuminaError) {
        let stream = try acquireTransferHandler()
        defer { releaseTransferHandler() }

        try send(.downloadReq(path: file.remotePath))

        // Receive chunks until eof
        var fileData = Data()
        var expectedSeq = 0
        var receivedEof = false

        for await response in stream {
            switch response {
            case .downloadData(_, let b64, let seq, let eof):
                guard seq == expectedSeq else {
                    throw .downloadFailed(path: file.remotePath, reason: "Seq mismatch: expected \(expectedSeq), got \(seq)")
                }
                guard let chunk = Data(base64Encoded: b64) else {
                    throw .downloadFailed(path: file.remotePath, reason: "Invalid base64 in chunk \(seq)")
                }
                fileData.append(chunk)
                expectedSeq += 1
                if eof { receivedEof = true }
            case .downloadError(_, let errorStr):
                throw .downloadFailed(path: file.remotePath, reason: errorStr)
            case .heartbeat:
                continue
            default:
                throw .protocolError("Expected download_data, got: \(response)")
            }
            if receivedEof { break }
        }

        // The loop also ends when the stream is finished by a dropped
        // connection (handleDispatcherError, resetForReconnect). Without this
        // guard that path wrote a truncated file and returned success — the
        // caller finds out later, when the tar it just "downloaded" fails.
        guard receivedEof else {
            throw .downloadFailed(
                path: file.remotePath,
                reason: "connection closed after \(expectedSeq) chunk(s) without EOF; file is incomplete"
            )
        }

        // Write to local path
        do {
            try fileData.write(to: file.localPath)
        } catch {
            throw .downloadFailed(path: file.remotePath, reason: "Cannot write local file: \(error)")
        }
    }

    // MARK: - Private: Dispatcher

    /// Start the background message dispatcher that routes all incoming guest
    /// messages to the appropriate handler.
    private func startDispatcher(initialBuffer: Data = Data()) {
        guard let input = getInputHandle() else { return }
        let generation = lock.withLock {
            dispatcherGeneration += 1
            return dispatcherGeneration
        }
        spawnBlockingThread("lumina.vsock-dispatcher") { [weak self] in
            var readBuffer = initialBuffer
            while let self {
                do {
                    let msg = try self.readGuestMessage(from: input, buffer: &readBuffer)
                    self.dispatchMessage(msg)
                } catch {
                    if self.lock.withLock({ self.dispatcherGeneration == generation }) {
                        self.handleDispatcherError(error)
                    }
                    return
                }
            }
        }
    }

    func close() {
        let fd = lock.withLock { () -> Int32? in
            dispatcherGeneration += 1
            return _connection?.fileDescriptor
        }
        if let fd { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    /// Route a guest message to the appropriate handler.
    /// Exec messages go to execHandlers by ID.
    /// Transfer messages go to the single transferContinuation.
    /// Heartbeats broadcast to all exec handlers.
    private func dispatchMessage(_ msg: GuestMessage) {
        switch msg {
        case .output(let id, _, _), .outputBinary(let id, _, _):
            lock.withLock { execHandlers[id] }?.yield(msg)
        case .ptyOutput(let id, _):
            ptyLock.withLock { ptyHandlers[id] }?.yield(msg)
        case .exit(let id, _):
            // Check exec handlers first (common case)
            if let h = lock.withLock({ execHandlers[id] }) {
                h.yield(msg)
                break
            }
            // Fall through to PTY handlers — separate lock to avoid lock coupling
            if let h = ptyLock.withLock({ ptyHandlers[id] }) {
                h.yield(msg)
                break
            }
            // Orphan exit: handler already unregistered. Drop.
            // For `exec()` / `execStream()`: the soft/hard deadline
            // grace window keeps the handler registered through the
            // natural-exit window, so by the time we land here the
            // command genuinely overshot the window and the synthetic
            // .timeout error is correct.
            // For `ptyExec()`: there is no host-side soft/hard
            // deadline pattern — PTY timeout is enforced solely by
            // the guest's gracefulKill (SIGTERM, then SIGKILL after
            // 5s). A late PTY exit can therefore land here if the
            // consumer cancelled or dropped the stream. This drop is
            // bounded by the guest's SIGKILL fallback so the process
            // can't outlive the host's cleanup; the PTY stream
            // closes either way. Pre-existing — not introduced by
            // the soft/hard deadline change.
            break
        case .heartbeat:
            // Broadcast to all exec handlers so timeout checks can run
            for h in lock.withLock({ Array(execHandlers.values) }) { h.yield(msg) }
        case .uploadAck, .uploadDone, .uploadError, .downloadData, .downloadError:
            // Route to the dedicated transfer handler
            lock.withLock { transferContinuation }?.yield(msg)
        case .networkReady:
            takeNetworkContinuation()?.resume(returning: msg)
        case .networkError(let reason, let attempts):
            // Guest couldn't bring up eth0 even after retries — the
            // route isn't installed, DNS won't resolve. Surface this
            // as a typed error to the waiting configureNetwork()
            // caller so the user sees "network setup failed: <reason>"
            // instead of a silent success followed by exec errors.
            takeNetworkContinuation()?.resume(throwing: LuminaError.protocolError(
                "guest network setup failed after \(attempts) attempt(s): \(reason)"
            ))
        case .networkMetrics(let interfaces):
            lock.withLock { _latestNetworkMetrics = NetworkMetricsSummary(interfaces: interfaces) }
        case .portForwardReady(let guestPort, let vsockPort):
            lock.withLock { portForwardContinuations.removeValue(forKey: guestPort) }?
                .resume(returning: vsockPort)
        case .portForwardError(let guestPort, let reason):
            // Guest refused the forward (double-start collision, vsock
            // bind failure, port space exhausted). Resume the caller
            // with a clear protocol error instead of letting them time
            // out on a forward that will never arrive.
            lock.withLock { portForwardContinuations.removeValue(forKey: guestPort) }?
                .resume(throwing: LuminaError.protocolError(
                "port_forward refused by guest for guest_port=\(guestPort): \(reason)"
            ))
        case .ready:
            // Unexpected ready during active connection — ignore
            break
        case .unknown(let type):
            NSLog("[Lumina.CommandRunner] Ignoring unknown guest message type: %@", type)
        }
    }

    /// Handle a dispatcher error (connection drop, protocol error).
    /// Fails all in-flight operations.
    private func handleDispatcherError(_ error: any Error) {
        NSLog("[Lumina.CommandRunner] Dispatcher error: %@", String(describing: error))
        _ = failAll(.failed, dropConnection: false)
    }

    private func takeNetworkContinuation() -> CheckedContinuation<GuestMessage, Error>? {
        lock.withLock {
            defer { networkContinuation = nil }
            return networkContinuation
        }
    }

    // MARK: - Private: Exec Handler Registration

    /// Register an exec handler and return the stream to read from.
    private func registerExecHandler(_ id: String) -> AsyncStream<GuestMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuestMessage.self)
        lock.withLock { execHandlers[id] = continuation }
        return stream
    }

    /// Inject a synthetic heartbeat into an exec handler's stream.
    /// Used by the timeout watchdog to unblock the for-await loop in exec().
    private func yieldSyntheticHeartbeat(to id: String) {
        lock.withLock { execHandlers[id] }?.yield(.heartbeat)
    }

    /// Unregister an exec handler and finish its stream.
    private func unregisterExecHandler(_ id: String) {
        lock.withLock { execHandlers.removeValue(forKey: id) }?.finish()
    }

    // MARK: - Private: Transfer Handler (singleton, guarded)

    /// Acquire the transfer handler slot. Throws if another transfer is active.
    private func acquireTransferHandler() throws(LuminaError) -> AsyncStream<GuestMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuestMessage.self)
        let failure: LuminaError? = lock.withLock {
            guard transferContinuation == nil else {
                return .protocolError("Another file transfer is already in progress")
            }
            guard _state == .ready else { return .connectionFailed }
            transferContinuation = continuation
            return nil
        }
        if let failure { throw failure }
        return stream
    }

    /// Release the transfer handler slot.
    private func releaseTransferHandler() {
        lock.withLock {
            defer { transferContinuation = nil }
            return transferContinuation
        }?.finish()
    }

    // MARK: - Private: Message Sending

    private func send(_ message: HostMessage) throws(LuminaError) {
        let data: Data
        do {
            data = try LuminaProtocol.encode(message)
        } catch {
            throw .protocolError("Failed to encode host message: \(error)")
        }
        try writeToOutput(data)
    }

    /// Write data to the vsock output handle.
    ///
    /// Dups the fd under the lock and releases immediately before writing so
    /// the lock is never held across a blocking syscall. This prevents a deadlock
    /// where the dispatcher (which also acquires the lock per message) is blocked
    /// waiting for the lock while a write stalls on vsock backpressure.
    ///
    /// Uses POSIX `write()` instead of `FileHandle.write()` — same reason as
    /// `SessionServer.writeResponse`: NSFileHandle raises an Obj-C exception on
    /// EPIPE that Swift's `try` cannot catch.
    ///
    /// The dup'd fd remains valid even if `resetForReconnect` closes the original
    /// between lock release and write. A failed write surfaces as `.connectionFailed`
    /// rather than a crash or deadlock.
    private func writeToOutput(_ data: Data) throws(LuminaError) {
        // Dup under lock, write after lock is released.
        let rawFd = lock.withLock { _outputHandle.map { dup($0.fileDescriptor) } ?? -1 }
        guard rawFd >= 0 else { throw .connectionFailed }
        defer { Darwin.close(rawFd) }
        guard writeAll(fd: rawFd, data: data) else { throw .connectionFailed }
    }

    // MARK: - Private: State & Connection

    private func setState(_ newState: ConnectionState) {
        lock.withLock { _state = newState }
    }

    /// Store a new vsock connection and create file handles for I/O.
    private func setConnection(_ conn: VZVirtioSocketConnection) {
        let fd = conn.fileDescriptor
        lock.withLock {
            _connection = conn
            _inputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            _outputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        }
    }

    /// Read connection state under lock (safe to call from async contexts).
    private func getConnectionInfo() -> (connected: Bool, input: FileHandle?) {
        lock.withLock { (_connection != nil, _inputHandle) }
    }

    private func getInputHandle() -> FileHandle? {
        lock.withLock { _inputHandle }
    }

    // MARK: - Private: Buffered Line Reader

    /// Read one newline-delimited message and decode it.
    private func readGuestMessage(from handle: FileHandle, buffer: inout Data) throws(LuminaError) -> GuestMessage {
        let lineData = try readLine(from: handle, buffer: &buffer)
        do {
            return try LuminaProtocol.decodeGuest(lineData)
        } catch let error as LuminaError {
            throw error
        } catch {
            throw .protocolError("Failed to decode guest message: \(error)")
        }
    }

    /// Buffered line reader. The buffer is owned by the dispatcher thread.
    private func readLine(from handle: FileHandle, buffer: inout Data) throws(LuminaError) -> Data {
        if let line = takeLine(from: &buffer) {
            return line
        }

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty {
                    throw .connectionFailed
                }
                let remaining = buffer
                buffer = Data()
                return remaining
            }

            buffer.append(chunk)

            if buffer.count > LuminaProtocol.maxMessageSize {
                buffer = Data()
                throw .protocolError("Message exceeds limit")
            }

            if let line = takeLine(from: &buffer) {
                return line
            }
        }
    }
}

public func spawnBlockingThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.name = name
    thread.start()
}

func takeLine(from buffer: inout Data) -> Data? {
    guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
    let end = buffer.index(after: newline)
    defer { buffer.removeSubrange(buffer.startIndex..<end) }
    return Data(buffer[buffer.startIndex..<end])
}
