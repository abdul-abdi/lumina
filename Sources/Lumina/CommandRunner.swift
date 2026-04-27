// Sources/Lumina/CommandRunner.swift
import Foundation
import os
@preconcurrency import Virtualization

enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case waitingForReady
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
    /// Per-exec guest-side timeout (seconds). Used by reconnect to compute
    /// retry duration as max(all in-flight timeouts).
    private var execTimeouts: [String: Int] = [:]

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

    // ── Guest handshake metadata (v0.7.2) ──
    // Captured from the agent's `ready` frame. 0 / [] when the guest
    // pre-dates capability negotiation (older release tarballs).
    // Diagnostic only today; future protocol bumps can branch on
    // these to refuse incompatible guests instead of misdecoding.
    private var _guestProtocolVersion: Int = 0
    private var _guestCapabilities: [String] = []

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

    // ── Port forward continuations: one per in-flight port_forward_start ──
    // Keyed by guestPort. Throwing so teardown (reset/dispatcher error) can
    // surface `.connectionFailed` to the caller instead of silently succeeding
    // with a bogus vsock port.
    private var portForwardContinuations: [Int: CheckedContinuation<Int, any Error>] = [:]

    /// Background task that reads all messages from the vsock and dispatches
    /// them to registered handlers.
    private var dispatcherTask: Task<Void, Never>?

    private static let vsockPort: UInt32 = 1024
    private static let maxRetries = 2000     // 2000 * 10ms = 20s max
    private static let retryInterval: UInt64 = 10_000_000  // 10ms — shaves ~10-15ms off cold boot (prev 20ms)

    /// Latest network metrics snapshot seen on this connection. nil when no
    /// metrics have arrived yet (short command + 500ms ticker delay, or
    /// pre-v0.7.1 agent with no ticker). Thread-safe read.
    var latestNetworkMetrics: NetworkMetricsSummary? {
        lock.lock()
        defer { lock.unlock() }
        return _latestNetworkMetrics
    }

    /// Wire-format version reported by the guest on its `ready` frame.
    /// 0 means the guest pre-dates v0.7.2 (no protocol_version field
    /// in its `ready`). Thread-safe read.
    var guestProtocolVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return _guestProtocolVersion
    }

    /// Capability strings reported by the guest on its `ready` frame.
    /// Empty when the guest pre-dates v0.7.2. Thread-safe read.
    var guestCapabilities: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _guestCapabilities
    }

    var state: ConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Number of exec commands currently in flight.
    var activeExecCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return execHandlers.count
    }

    init(socketDevice: VZVirtioSocketDevice, queue: DispatchQueue) {
        self.socketDevice = socketDevice
        self.queue = queue
    }

    // MARK: - Connect

    func connect(maxRetries: Int = maxRetries) async throws(LuminaError) {
        setState(.connecting)

        for _ in 0..<maxRetries {
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
        setState(.waitingForReady)
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
        guard case .ready(let protocolVersion, let capabilities) = msg else {
            setState(.disconnected)
            throw .protocolError("Expected ready message, got: \(msg)")
        }

        // Stash handshake metadata for diagnostics + future capability
        // gating. v0.7.2+ agents populate these; older guests omit the
        // fields and decode as (0, []) which is fine.
        setHandshakeMetadata(protocolVersion: protocolVersion, capabilities: capabilities)

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
        let guestTimeout = max(timeout * 3, 30)
        let stream = registerExecHandler(id, guestTimeout: guestTimeout)
        defer { unregisterExecHandler(id) }

        try sendExecMessage(id: id, command: command, guestTimeout: guestTimeout, env: env, cwd: cwd)
        // Exec message is now on the wire; safe for callers to start the
        // stdin pump. Called synchronously on the current task's thread,
        // so any downstream Task.resume() it does happens-after the exec
        // message reaches the vsock.
        afterDispatched?()

        var stdout = ""
        var stderr = ""
        // Binary accumulators only populated when the guest emits at least one
        // base64-encoded (non-UTF-8) chunk. If every chunk is UTF-8 these stay
        // nil and RunResult.stdoutBytes/stderrBytes are nil.
        var stdoutBytes: Data? = nil
        var stderrBytes: Data? = nil

        // Two deadlines (v0.7.2 audit follow-up):
        //
        //   softDeadline = T+timeout   — watchdog fires SIGTERM here and
        //                                 wakes the loop, but we keep
        //                                 reading the stream looking
        //                                 for a natural exit.
        //   hardDeadline = soft+grace  — only here do we throw `.timeout`.
        //
        // The grace window between them lets a command that finished
        // a hair after the timeout fired report its real exit code
        // instead of getting a synthetic timeout error. Without this,
        // agents retrying non-idempotent operations could repeat work
        // that actually succeeded.
        let softDeadline = ContinuousClock.now + .seconds(timeout)
        let hardDeadline = softDeadline + Self.lateExitGraceWindow

        // Watchdog: two wakeups. First at soft deadline (send cancel +
        // wake the loop so it stops blocking on for-await). Second at
        // hard deadline (wake the loop again so it sees `now > hard`
        // and throws — without this, the loop would block forever if
        // no late exit arrives during grace).
        let watchdogId = id
        let watchdog = Task.detached { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self else { return }
            try? self.cancel(id: watchdogId, signal: 15, gracePeriod: 5)
            self.yieldSyntheticHeartbeat(to: watchdogId)
            do { try await Task.sleep(for: Self.lateExitGraceWindow) } catch { return }
            self.yieldSyntheticHeartbeat(to: watchdogId)
        }
        defer { watchdog.cancel() }

        for await msg in stream {
            if ContinuousClock.now > hardDeadline {
                // Grace window expired without a natural exit. Genuine
                // timeout — cancel is idempotent so an extra send here
                // is fine if the watchdog already fired one.
                try? cancel(id: id, signal: 15, gracePeriod: 5)
                throw .timeout
            }
            switch msg {
            case .output(_, let s, let data):
                switch s {
                case .stdout:
                    stdout += data
                    stdoutBytes?.append(Data(data.utf8))
                case .stderr:
                    stderr += data
                    stderrBytes?.append(Data(data.utf8))
                }
            case .outputBinary(_, let s, let bytes):
                // First binary chunk: seed the bytes accumulator with whatever
                // UTF-8 text has been collected so far, so downstream consumers
                // reading stdoutBytes get a byte-exact view of the full stream.
                switch s {
                case .stdout:
                    if stdoutBytes == nil { stdoutBytes = Data(stdout.utf8) }
                    stdoutBytes?.append(bytes)
                    // Also append a best-effort UTF-8 view to `stdout` so text-only
                    // consumers see approximate output; may contain replacement chars.
                    stdout += String(decoding: bytes, as: UTF8.self)
                case .stderr:
                    if stderrBytes == nil { stderrBytes = Data(stderr.utf8) }
                    stderrBytes?.append(bytes)
                    stderr += String(decoding: bytes, as: UTF8.self)
                }
            case .exit(_, let code):
                return RunResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: code,
                    wallTime: .zero,
                    stdoutBytes: stdoutBytes,
                    stderrBytes: stderrBytes,
                    networkMetrics: latestNetworkMetrics
                )
            case .heartbeat:
                continue
            default:
                break
            }
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
        let guestTimeout = max(timeout * 3, 30)
        let msgStream = registerExecHandler(id, guestTimeout: guestTimeout)

        // If sendExecMessage throws, the AsyncThrowingStream is never created and
        // onTermination is never registered, so we must explicitly clean up here.
        do {
            try sendExecMessage(id: id, command: command, guestTimeout: guestTimeout, env: env, cwd: cwd)
        } catch {
            unregisterExecHandler(id)
            throw error
        }
        afterDispatched?()

        let runner = self
        let execId = id

        return AsyncThrowingStream { continuation in
            // Soft/hard deadline pattern — same rationale as `exec()`.
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
        let msg = HostMessage.stdin(id: id, data: data)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode stdin message: \(error)")
        }
        try writeToOutput(msgData)
    }

    /// Close the stdin pipe for a running command.
    func closeStdin(id: String) throws(LuminaError) {
        let msg = HostMessage.stdinClose(id: id)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode stdin_close message: \(error)")
        }
        try writeToOutput(msgData)
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
        lock.lock()
        let currentState = _state
        lock.unlock()
        guard currentState == .ready else {
            throw .connectionFailed
        }

        let (stream, continuation) = AsyncStream<GuestMessage>.makeStream()

        ptyLock.lock()
        ptyHandlers[id] = continuation
        ptyLock.unlock()

        // Send pty_exec message
        let msg = HostMessage.ptyExec(id: id, cmd: command, timeout: timeout, env: env, cols: cols, rows: rows)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            ptyLock.lock()
            ptyHandlers.removeValue(forKey: id)
            ptyLock.unlock()
            continuation.finish()
            throw .protocolError("Failed to encode pty_exec message: \(error)")
        }
        do {
            try writeToOutput(msgData)
        } catch {
            ptyLock.lock()
            ptyHandlers.removeValue(forKey: id)
            ptyLock.unlock()
            continuation.finish()
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
                    case .heartbeat:
                        continue
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
        ptyLock.lock()
        let cont = ptyHandlers.removeValue(forKey: id)
        ptyLock.unlock()
        cont?.finish()
    }

    /// Send raw input bytes to a running PTY session.
    func sendPtyInput(id: String, data: Data) throws(LuminaError) {
        let base64 = data.base64EncodedString()
        let msg = HostMessage.ptyInput(id: id, data: base64)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode pty_input message: \(error)")
        }
        try writeToOutput(msgData)
    }

    /// Send a window resize event to a running PTY session.
    func sendWindowResize(id: String, cols: Int, rows: Int) throws(LuminaError) {
        let msg = HostMessage.windowResize(id: id, cols: cols, rows: rows)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode window_resize message: \(error)")
        }
        try writeToOutput(msgData)
    }

    // MARK: - Reconnect

    /// Max guest-side timeout across all in-flight execs.
    /// Used by reconnect to determine how long to retry.
    private var maxInFlightTimeout: Int {
        lock.lock()
        defer { lock.unlock() }
        return execTimeouts.values.max() ?? 0
    }

    /// Reconnect after a connection drop or timeout.
    /// Uses the max timeout across all in-flight execs to determine retry duration.
    func reconnect() async throws(LuminaError) {
        let maxTimeout = maxInFlightTimeout

        resetForReconnect()

        // The guest agent accepts new connections after the old one closes.
        // Retry long enough to cover the longest in-flight command.
        let retries = maxTimeout > 0
            ? max(Self.maxRetries, (maxTimeout + 15) * 50)
            : Self.maxRetries
        try await connect(maxRetries: retries)
    }

    /// Reset all connection state. Sends cancel to guest, closes fd,
    /// finishes all exec handlers and any active transfer.
    private func resetForReconnect() {
        dispatcherTask?.cancel()

        lock.lock()
        let fd = _connection?.fileDescriptor
        _connection = nil
        _inputHandle = nil
        _outputHandle = nil
        _state = .disconnected

        let execHandlersCopy = execHandlers
        execHandlers = [:]
        execTimeouts = [:]

        let transferCont = transferContinuation
        transferContinuation = nil

        let networkCont = networkContinuation
        networkContinuation = nil

        let pfConts = portForwardContinuations
        portForwardContinuations = [:]
        lock.unlock()

        ptyLock.lock()
        let ptyHandlersCopy = ptyHandlers
        ptyHandlers = [:]
        ptyLock.unlock()

        // Finish all handlers — unblocks any waiting exec/stream/upload/download
        for (_, handler) in execHandlersCopy { handler.finish() }
        for (_, handler) in ptyHandlersCopy { handler.finish() }
        transferCont?.finish()
        // Resume any pending configureNetwork() caller with a real error —
        // the connection died before the guest replied with network_ready.
        networkCont?.resume(throwing: LuminaError.connectionFailed)
        // Resume any pending requestPortForward() callers with connectionFailed.
        for (_, cont) in pfConts { cont.resume(throwing: LuminaError.connectionFailed) }

        // Best-effort cancel: tell the guest agent to kill running commands
        if let fd = fd {
            let msg = HostMessage.cancel(id: nil, signal: 9, gracePeriod: 0)
            if let data = try? LuminaProtocol.encode(msg) {
                data.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress {
                        _ = Darwin.write(fd, base, buffer.count)
                    }
                }
            }
        }

        // Close the fd — this unblocks the dispatcher's readLine (EOF)
        if let fd = fd {
            Darwin.close(fd)
        }

        dispatcherTask = nil
    }

    // MARK: - Cancel

    /// Send a cancel message to the guest agent.
    /// If id is nil, cancels all running commands.
    func cancel(id: String? = nil, signal: Int32 = 15, gracePeriod: Int = 5) throws(LuminaError) {
        let msg = HostMessage.cancel(id: id, signal: signal, gracePeriod: gracePeriod)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode cancel message: \(error)")
        }
        try writeToOutput(msgData)
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
        let msg = HostMessage.configureNetwork(ip: ip, gateway: gateway, dns: dns)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode configure_network: \(error)")
        }

        // Register continuation BEFORE sending the message to avoid a race
        // where the guest replies before we're ready to receive. The
        // throwing continuation lets teardown surface as a real error
        // instead of a synthetic `.networkReady(ip:"")` success.
        let reply: GuestMessage
        do {
            reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GuestMessage, Error>) in
                lock.lock()
                networkContinuation = cont
                lock.unlock()
                // Now safe to send — reply routes to cont via the dispatcher.
                do {
                    try writeToOutput(msgData)
                } catch {
                    // writeToOutput failed — unregister and resume so the caller doesn't hang.
                    lock.lock()
                    networkContinuation = nil
                    lock.unlock()
                    cont.resume(throwing: error)
                }
            }
        } catch let err as LuminaError {
            throw err
        } catch {
            throw .connectionFailed
        }
        // network_ready received; DNS, route, and IP are now live on the guest.
        if case .networkReady(_, let configMs, let stage) = reply {
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
        let msg = HostMessage.portForwardStart(guestPort: guestPort)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode port_forward_start: \(error)")
        }

        // Register continuation BEFORE sending so a fast guest reply cannot
        // arrive before the map entry exists. All lock operations happen inside
        // this synchronous closure — NSLock is async-unavailable in Swift 6.
        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, any Error>) in
                lock.lock()
                guard _state == .ready else {
                    lock.unlock()
                    cont.resume(throwing: LuminaError.connectionFailed)
                    return
                }
                if portForwardContinuations[guestPort] != nil {
                    lock.unlock()
                    cont.resume(throwing: LuminaError.protocolError(
                        "port_forward_start already in flight for guest port \(guestPort)"
                    ))
                    return
                }
                portForwardContinuations[guestPort] = cont
                lock.unlock()

                do {
                    try writeToOutput(msgData)
                } catch {
                    // writeToOutput failed — remove entry and resume before
                    // the dispatcher has any chance of finding it.
                    lock.lock()
                    let pending = portForwardContinuations.removeValue(forKey: guestPort)
                    lock.unlock()
                    pending?.resume(throwing: LuminaError.connectionFailed)
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
        let msg = HostMessage.portForwardStop(guestPort: guestPort)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode port_forward_stop: \(error)")
        }
        try writeToOutput(msgData)
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

            let msg = HostMessage.upload(
                path: file.remotePath, data: b64, mode: file.mode, seq: seq, eof: isEof
            )
            let msgData: Data
            do {
                msgData = try LuminaProtocol.encode(msg)
            } catch {
                throw .protocolError("Failed to encode upload message: \(error)")
            }
            try writeToOutput(msgData)

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
    }

    // MARK: - File Download (async, through dispatcher)

    /// Download a file from the guest via the vsock protocol.
    /// Only one transfer (upload or download) can be active at a time.
    func download(_ file: FileDownload) async throws(LuminaError) {
        let stream = try acquireTransferHandler()
        defer { releaseTransferHandler() }

        let msg = HostMessage.downloadReq(path: file.remotePath)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(msg)
        } catch {
            throw .protocolError("Failed to encode download_req: \(error)")
        }
        try writeToOutput(msgData)

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
        dispatcherTask = Task.detached { [weak self] in
            var readBuffer = initialBuffer
            while !Task.isCancelled {
                guard let self = self else { return }
                let msg: GuestMessage
                do {
                    msg = try self.readGuestMessage(from: input, buffer: &readBuffer)
                } catch {
                    self.handleDispatcherError(error)
                    return
                }
                self.dispatchMessage(msg)
            }
        }
    }

    /// Route a guest message to the appropriate handler.
    /// Exec messages go to execHandlers by ID.
    /// Transfer messages go to the single transferContinuation.
    /// Heartbeats broadcast to all exec handlers.
    private func dispatchMessage(_ msg: GuestMessage) {
        switch msg {
        case .output(let id, _, _), .outputBinary(let id, _, _):
            lock.lock()
            let handler = execHandlers[id]
            lock.unlock()
            handler?.yield(msg)
        case .ptyOutput(let id, _):
            ptyLock.lock()
            let handler = ptyHandlers[id]
            ptyLock.unlock()
            handler?.yield(msg)
        case .exit(let id, _):
            // Check exec handlers first (common case)
            lock.lock()
            let execHandler = execHandlers[id]
            lock.unlock()
            if let h = execHandler {
                h.yield(msg)
                break
            }
            // Fall through to PTY handlers — separate lock to avoid lock coupling
            ptyLock.lock()
            let ptyHandler = ptyHandlers[id]
            ptyLock.unlock()
            if let h = ptyHandler {
                h.yield(msg)
                break
            }
            // Orphan exit: handler already unregistered. Drop.
            // Pre-fix this was the silent-loss path; the soft/hard
            // deadline grace window in `exec()` keeps the handler
            // registered through the natural-exit window, so by the
            // time we land here the command genuinely overshot the
            // window and the synthetic .timeout error is correct.
            break
        case .heartbeat:
            // Broadcast to all exec handlers so timeout checks can run
            lock.lock()
            let handlers = Array(execHandlers.values)
            lock.unlock()
            for h in handlers { h.yield(msg) }
        case .uploadAck, .uploadDone, .uploadError, .downloadData, .downloadError:
            // Route to the dedicated transfer handler
            lock.lock()
            let handler = transferContinuation
            lock.unlock()
            handler?.yield(msg)
        case .networkReady:
            lock.lock()
            let cont = networkContinuation
            networkContinuation = nil
            lock.unlock()
            cont?.resume(returning: msg)
        case .networkError(let reason, let attempts):
            // Guest couldn't bring up eth0 even after retries — the
            // route isn't installed, DNS won't resolve. Surface this
            // as a typed error to the waiting configureNetwork()
            // caller so the user sees "network setup failed: <reason>"
            // instead of a silent success followed by exec errors.
            lock.lock()
            let cont = networkContinuation
            networkContinuation = nil
            lock.unlock()
            cont?.resume(throwing: LuminaError.protocolError(
                "guest network setup failed after \(attempts) attempt(s): \(reason)"
            ))
        case .networkMetrics(let interfaces):
            lock.lock()
            _latestNetworkMetrics = NetworkMetricsSummary(interfaces: interfaces)
            lock.unlock()
        case .portForwardReady(let guestPort, let vsockPort):
            lock.lock()
            let cont = portForwardContinuations.removeValue(forKey: guestPort)
            lock.unlock()
            cont?.resume(returning: vsockPort)
        case .portForwardError(let guestPort, let reason):
            // Guest refused the forward (double-start collision, vsock
            // bind failure, port space exhausted). Resume the caller
            // with a clear protocol error instead of letting them time
            // out on a forward that will never arrive.
            lock.lock()
            let cont = portForwardContinuations.removeValue(forKey: guestPort)
            lock.unlock()
            cont?.resume(throwing: LuminaError.protocolError(
                "port_forward refused by guest for guest_port=\(guestPort): \(reason)"
            ))
        case .ready:
            // Unexpected ready during active connection — ignore
            break
        }
    }

    /// Handle a dispatcher error (connection drop, protocol error).
    /// Fails all in-flight operations.
    private func handleDispatcherError(_ error: any Error) {
        NSLog("[Lumina.CommandRunner] Dispatcher error: %@", String(describing: error))

        lock.lock()
        _state = .failed

        let execHandlersCopy = execHandlers
        execHandlers = [:]
        execTimeouts = [:]

        let transferCont = transferContinuation
        transferContinuation = nil

        let networkCont = networkContinuation
        networkContinuation = nil

        let pfConts = portForwardContinuations
        portForwardContinuations = [:]
        lock.unlock()

        ptyLock.lock()
        let ptyHandlersCopy = ptyHandlers
        ptyHandlers = [:]
        ptyLock.unlock()

        // Finish all handlers so waiting callers get unblocked
        for (_, handler) in execHandlersCopy { handler.finish() }
        for (_, handler) in ptyHandlersCopy { handler.finish() }
        transferCont?.finish()
        // Resume any pending configureNetwork() caller with a real error —
        // the connection died before the guest replied with network_ready.
        networkCont?.resume(throwing: LuminaError.connectionFailed)
        // Resume any pending requestPortForward() callers with connectionFailed.
        for (_, cont) in pfConts { cont.resume(throwing: LuminaError.connectionFailed) }
    }

    // MARK: - Private: Exec Handler Registration

    /// Register an exec handler and return the stream to read from.
    /// Tracks the guest-side timeout for reconnect calculations.
    private func registerExecHandler(_ id: String, guestTimeout: Int) -> AsyncStream<GuestMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuestMessage.self)
        lock.lock()
        execHandlers[id] = continuation
        execTimeouts[id] = guestTimeout
        lock.unlock()
        return stream
    }

    /// Inject a synthetic heartbeat into an exec handler's stream.
    /// Used by the timeout watchdog to unblock the for-await loop in exec().
    private func yieldSyntheticHeartbeat(to id: String) {
        lock.lock()
        let handler = execHandlers[id]
        lock.unlock()
        handler?.yield(.heartbeat)
    }

    /// Unregister an exec handler and finish its stream.
    private func unregisterExecHandler(_ id: String) {
        lock.lock()
        let cont = execHandlers.removeValue(forKey: id)
        execTimeouts.removeValue(forKey: id)
        lock.unlock()
        cont?.finish()
    }

    // MARK: - Private: Transfer Handler (singleton, guarded)

    /// Acquire the transfer handler slot. Throws if another transfer is active.
    private func acquireTransferHandler() throws(LuminaError) -> AsyncStream<GuestMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuestMessage.self)
        lock.lock()
        guard transferContinuation == nil else {
            lock.unlock()
            throw .protocolError("Another file transfer is already in progress")
        }
        guard _state == .ready else {
            lock.unlock()
            throw .connectionFailed
        }
        transferContinuation = continuation
        lock.unlock()
        return stream
    }

    /// Release the transfer handler slot.
    private func releaseTransferHandler() {
        lock.lock()
        let cont = transferContinuation
        transferContinuation = nil
        lock.unlock()
        cont?.finish()
    }

    // MARK: - Private: Message Sending

    private func sendExecMessage(id: String, command: String, guestTimeout: Int, env: [String: String], cwd: String? = nil) throws(LuminaError) {
        lock.lock()
        guard _state == .ready else {
            lock.unlock()
            throw .connectionFailed
        }
        lock.unlock()

        let execMsg = HostMessage.exec(id: id, cmd: command, timeout: guestTimeout, env: env, cwd: cwd)
        let msgData: Data
        do {
            msgData = try LuminaProtocol.encode(execMsg)
        } catch {
            throw .protocolError("Failed to encode host message: \(error)")
        }
        try writeToOutput(msgData)
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
        let rawFd: Int32
        lock.lock()
        guard let output = _outputHandle else {
            lock.unlock()
            throw .connectionFailed
        }
        rawFd = dup(output.fileDescriptor)
        lock.unlock()

        guard rawFd >= 0 else { throw .connectionFailed }
        defer { Darwin.close(rawFd) }

        var remaining = data.count
        var offset = 0
        while remaining > 0 {
            let written: Int = data.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                var n: Int
                repeat { n = Darwin.write(rawFd, base + offset, remaining) } while n < 0 && errno == EINTR
                return n
            }
            if written <= 0 { throw .connectionFailed }
            offset += written
            remaining -= written
        }
    }

    // MARK: - Private: State & Connection

    private func setState(_ newState: ConnectionState) {
        lock.lock()
        _state = newState
        lock.unlock()
    }

    /// Sync wrapper so async callers (connect) can stash the guest's
    /// handshake metadata without touching the NSLock directly —
    /// `lock.lock()` is unavailable from async contexts under Swift 6
    /// strict concurrency.
    private func setHandshakeMetadata(protocolVersion: Int, capabilities: [String]) {
        lock.lock()
        _guestProtocolVersion = protocolVersion
        _guestCapabilities = capabilities
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

    private func getInputHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        return _inputHandle
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

    /// Buffered line reader. The buffer is owned by the caller (the dispatcher task)
    /// to avoid shared mutable state. Stays synchronous: the dispatcher is a
    /// single long-lived `Task.detached` per VM, so blocking on its own thread
    /// does not starve the cooperative pool the way per-connection handlers
    /// would. (Per-connection callers in SessionServer use an async read for
    /// exactly that reason; see SessionServer.readMessage.)
    private func readLine(from handle: FileHandle, buffer: inout Data) throws(LuminaError) -> Data {
        if let line = extractLine(from: &buffer) {
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

            if let line = extractLine(from: &buffer) {
                return line
            }
        }
    }

    /// Extract a complete line (including the newline) from a buffer, or nil.
    private func extractLine(from buffer: inout Data) -> Data? {
        guard let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        let lineEnd = buffer.index(after: newlineIndex)
        let line = Data(buffer[buffer.startIndex..<lineEnd])
        buffer.removeSubrange(buffer.startIndex..<lineEnd)
        return line
    }
}
