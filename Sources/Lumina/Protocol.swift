import Foundation

// MARK: - Host Messages (sent to guest)

public enum HostMessage: Sendable {
    case exec(id: String, cmd: String, timeout: Int, env: [String: String], cwd: String? = nil)
    case upload(path: String, data: String, mode: String, seq: Int, eof: Bool)
    case downloadReq(path: String)
    /// Send a signal to a running command (by id) or all commands (id nil).
    /// The guest sends `signal` to the process group, waits `gracePeriod` seconds, then SIGKILL.
    case cancel(id: String?, signal: Int32, gracePeriod: Int)
    case stdin(id: String, data: String)
    case stdinClose(id: String)
    case configureNetwork(ip: String, gateway: String, dns: String)
    /// Start a PTY-backed interactive command. Output flows back as `.ptyOutput`
    /// and the process exits via the shared `.exit(id:code:)` message.
    case ptyExec(id: String, cmd: String, timeout: Int, env: [String: String], cols: Int, rows: Int)
    /// Write base64-encoded bytes to a running PTY's master side (keyboard input).
    case ptyInput(id: String, data: String)
    case windowResize(id: String, cols: Int, rows: Int)
    /// Tell the guest agent to start forwarding a TCP port. The guest listens on
    /// `guestPort`, picks an available vsock port for the reverse channel, and
    /// replies with `.portForwardReady(guestPort:vsockPort:)`. Each new TCP
    /// connection on the guest side opens a fresh vsock connection back to host.
    case portForwardStart(guestPort: Int)
    /// Tell the guest agent to stop forwarding a TCP port. Idempotent.
    case portForwardStop(guestPort: Int)
}

// MARK: - Guest Messages (received from guest)

public enum GuestMessage: Sendable, Equatable {
    /// Initial handshake from the guest agent. `protocolVersion` is 0 when
    /// absent (pre-v0.7.2 agent).
    case ready(protocolVersion: Int)
    /// Text output (UTF-8). `data` carries the text verbatim.
    case output(id: String, stream: OutputStream, data: String)
    /// Binary output. `bytes` carries the raw bytes that were base64-encoded
    /// on the wire. Produced when the guest detects a non-UTF-8 chunk via
    /// `utf8.Valid()` before emitting.
    case outputBinary(id: String, stream: OutputStream, bytes: Data)
    case exit(id: String, code: Int32)
    case heartbeat
    case uploadAck(seq: Int)
    case uploadDone(path: String)
    case uploadError(path: String, error: String)
    case downloadData(path: String, data: String, seq: Int, eof: Bool)
    case downloadError(path: String, error: String)
    /// Guest network is live. `configMs` is the guest-side setup
    /// duration (from configure_network receipt to ready emission);
    /// `stage` annotates which gate fired — "operstate", "carrier",
    /// or "timeout-anyway" (the defensive fallback where route is
    /// verified but carrier poll timed out). Old-agent compatibility:
    /// configMs defaults to 0 and stage to empty when absent.
    case networkReady(ip: String, configMs: Int, stage: String, dnsOk: Bool)
    /// Guest failed to bring up the network. `reason` is a human-
    /// readable diagnostic; `attempts` counts how many ip-command
    /// retries ran before giving up. The host propagates this to
    /// the pending `configureNetwork` caller as a typed
    /// `LuminaError.networkConfigFailed`.
    case networkError(reason: String, attempts: Int)
    /// Periodic per-NIC counter snapshot from the guest. Map is
    /// keyed by interface name (e.g. `"eth0"`); loopback is excluded
    /// guest-side. Counters are cumulative since interface-up —
    /// hosts compute deltas themselves if they want throughput.
    case networkMetrics(interfaces: [String: InterfaceCounters])
    /// PTY-backed output (merged stdout+stderr). `data` is the base64-encoded raw bytes
    /// read from the PTY master. Exit is delivered via the shared `.exit(id:code:)` case.
    case ptyOutput(id: String, data: String)
    /// Acknowledge that the guest-side TCP listener is up for a port forward.
    /// `vsockPort` is the reverse-channel port the host should connect to for
    /// each new proxied TCP connection.
    case portForwardReady(guestPort: Int, vsockPort: Int)
    /// Guest refused to establish a forward on `guestPort` for the attached
    /// reason. Typically "already active" (double-start collision) or a
    /// guest-side vsock bind failure. The host surfaces the reason to the
    /// caller waiting on `requestPortForward(...)`.
    case portForwardError(guestPort: Int, reason: String)
    /// A well-formed frame whose `type` this host does not implement — almost
    /// always a newer guest. Carried so the dispatcher can skip it instead of
    /// treating it as a fatal decode error.
    case unknown(type: String)
}

public enum OutputStream: String, Sendable, Equatable, Codable {
    case stdout
    case stderr
}

/// Per-NIC counter snapshot. Wire format carries `rx_bytes` / `tx_bytes` /
/// `rx_errors` / `tx_errors` / `rx_packets` / `tx_packets` — all cumulative
/// since the interface came up on the guest. Missing fields default to 0 for
/// forward compatibility with older agents that may ship a subset.
public struct InterfaceCounters: Sendable, Equatable, Codable {
    public let rxBytes: UInt64
    public let txBytes: UInt64
    public let rxErrors: UInt64
    public let txErrors: UInt64
    public let rxPackets: UInt64
    public let txPackets: UInt64

    public init(
        rxBytes: UInt64 = 0,
        txBytes: UInt64 = 0,
        rxErrors: UInt64 = 0,
        txErrors: UInt64 = 0,
        rxPackets: UInt64 = 0,
        txPackets: UInt64 = 0
    ) {
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxErrors = rxErrors
        self.txErrors = txErrors
        self.rxPackets = rxPackets
        self.txPackets = txPackets
    }

    enum CodingKeys: String, CodingKey {
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case rxErrors = "rx_errors"
        case txErrors = "tx_errors"
        case rxPackets = "rx_packets"
        case txPackets = "tx_packets"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys) throws -> UInt64 { try c.decodeIfPresent(UInt64.self, forKey: key) ?? 0 }
        self.init(
            rxBytes: try field(.rxBytes), txBytes: try field(.txBytes),
            rxErrors: try field(.rxErrors), txErrors: try field(.txErrors),
            rxPackets: try field(.rxPackets), txPackets: try field(.txPackets)
        )
    }
}

// MARK: - Wire Format

private struct HostFrame: Encodable {
    var type: String
    var id: String?
    var cmd: String?
    var timeout: Int?
    var env: [String: String]?
    var cwd: String?
    var path: String?
    var data: String?
    var mode: String?
    var seq: Int?
    var eof: Bool?
    var signal: Int?
    var grace_period: Int?
    var ip: String?
    var gateway: String?
    var dns: String?
    var cols: Int?
    var rows: Int?
    var guest_port: Int?
}

private struct GuestFrame: Decodable {
    var type: String
    var protocol_version: Int?
    var id: String?
    var stream: OutputStream?
    var data: String?
    var encoding: String?
    var code: Int?
    var seq: Int?
    var eof: Bool?
    var path: String?
    var error: String?
    var ip: String?
    var config_ms: Int?
    var stage: String?
    var dns_ok: Bool?
    var reason: String?
    var attempts: Int?
    var interfaces: [String: InterfaceCounters]?
    var guest_port: Int?
    var vsock_port: Int?

    func need<T>(_ value: T?) throws -> T {
        guard let value else { throw LuminaError.protocolError("Malformed \(type) message") }
        return value
    }
}

private struct FrameType: Decodable {
    var type: String
}

enum LuminaProtocol {
    // 128KB — must accommodate 48KB raw chunks from guest agent (48*4/3 ≈ 64KB base64 + JSON envelope).
    static let maxMessageSize = 131_072

    private static let knownGuestTypes: Set<String> = [
        "ready", "output", "exit", "heartbeat", "upload_ack", "upload_done", "upload_error",
        "download_data", "download_error", "network_ready", "network_error", "network_metrics",
        "pty_output", "port_forward_ready", "port_forward_error",
    ]

    static func encode(_ message: HostMessage) throws -> Data {
        let frame: HostFrame
        switch message {
        case .exec(let id, let cmd, let timeout, let env, let cwd):
            frame = HostFrame(type: "exec", id: id, cmd: cmd, timeout: timeout, env: env, cwd: cwd)
        case .upload(let path, let data, let mode, let seq, let eof):
            frame = HostFrame(type: "upload", path: path, data: data, mode: mode, seq: seq, eof: eof)
        case .downloadReq(let path):
            frame = HostFrame(type: "download_req", path: path)
        case .cancel(let id, let signal, let gracePeriod):
            frame = HostFrame(type: "cancel", id: id, signal: Int(signal), grace_period: gracePeriod)
        case .stdin(let id, let data):
            frame = HostFrame(type: "stdin", id: id, data: data)
        case .stdinClose(let id):
            frame = HostFrame(type: "stdin_close", id: id)
        case .configureNetwork(let ip, let gateway, let dns):
            frame = HostFrame(type: "configure_network", ip: ip, gateway: gateway, dns: dns)
        case .ptyExec(let id, let cmd, let timeout, let env, let cols, let rows):
            frame = HostFrame(type: "pty_exec", id: id, cmd: cmd, timeout: timeout, env: env, cols: cols, rows: rows)
        case .ptyInput(let id, let data):
            frame = HostFrame(type: "pty_input", id: id, data: data)
        case .windowResize(let id, let cols, let rows):
            frame = HostFrame(type: "window_resize", id: id, cols: cols, rows: rows)
        case .portForwardStart(let guestPort):
            frame = HostFrame(type: "port_forward_start", guest_port: guestPort)
        case .portForwardStop(let guestPort):
            frame = HostFrame(type: "port_forward_stop", guest_port: guestPort)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(frame) + [UInt8(ascii: "\n")]
    }

    static func decodeGuest(_ data: Data) throws -> GuestMessage {
        let line = data.prefix(while: { $0 != UInt8(ascii: "\n") })
        let f: GuestFrame
        do {
            f = try JSONDecoder().decode(GuestFrame.self, from: line)
        } catch {
            // Forward compatibility: a frame this host has never heard of must
            // not be fatal. Throwing here reached handleDispatcherError, which
            // tears down the dispatcher for the whole VM and fails every
            // in-flight exec, PTY and transfer on it — so one new frame from a
            // newer guest bricked a running VM. Malformed *known* types still throw.
            if let type = try? JSONDecoder().decode(FrameType.self, from: line).type, !knownGuestTypes.contains(type) {
                return .unknown(type: type)
            }
            throw LuminaError.protocolError("Invalid JSON in guest message")
        }

        switch f.type {
        case "ready":
            return .ready(protocolVersion: f.protocol_version ?? 0)
        case "output":
            let (id, stream, text) = (try f.need(f.id), try f.need(f.stream), try f.need(f.data))
            // Old guests never set "encoding" → UTF-8 text. New guests emitting
            // non-UTF-8 chunks set "encoding":"base64".
            guard f.encoding == "base64" else { return .output(id: id, stream: stream, data: text) }
            guard let bytes = Data(base64Encoded: text) else {
                throw LuminaError.protocolError("Malformed base64 output data")
            }
            return .outputBinary(id: id, stream: stream, bytes: bytes)
        case "exit":
            return .exit(id: try f.need(f.id), code: Int32(try f.need(f.code)))
        case "heartbeat":
            return .heartbeat
        case "upload_ack":
            return .uploadAck(seq: try f.need(f.seq))
        case "upload_done":
            return .uploadDone(path: try f.need(f.path))
        case "upload_error":
            return .uploadError(path: try f.need(f.path), error: try f.need(f.error))
        case "download_data":
            return .downloadData(path: try f.need(f.path), data: try f.need(f.data), seq: try f.need(f.seq), eof: try f.need(f.eof))
        case "download_error":
            return .downloadError(path: try f.need(f.path), error: try f.need(f.error))
        case "network_ready":
            // dns_ok is absent on pre-v0.7.3 agents, which wrote resolv.conf
            // without checking. Defaulting to true keeps them quiet rather than
            // warning about a condition we cannot observe.
            return .networkReady(ip: f.ip ?? "", configMs: f.config_ms ?? 0, stage: f.stage ?? "", dnsOk: f.dns_ok ?? true)
        case "network_error":
            return .networkError(reason: f.reason ?? "unspecified", attempts: f.attempts ?? 0)
        case "network_metrics":
            return .networkMetrics(interfaces: f.interfaces ?? [:])
        case "pty_output":
            return .ptyOutput(id: try f.need(f.id), data: try f.need(f.data))
        case "port_forward_ready":
            return .portForwardReady(guestPort: try f.need(f.guest_port), vsockPort: try f.need(f.vsock_port))
        case "port_forward_error":
            return .portForwardError(guestPort: try f.need(f.guest_port), reason: f.reason ?? "unspecified")
        default:
            return .unknown(type: f.type)
        }
    }
}

// MARK: - Public alias using backtick-escaped name

typealias Protocol = LuminaProtocol

// MARK: - Stale guest image detection

let expectedGuestProtocolVersion = 1

/// Images older than that run `udhcpc` from `/sbin/init`, whose `deconfig`
/// hook flushes the address the host just installed over vsock. The VM
/// boots and execs fine, so the only symptom is that nothing reaches the
/// network — worth naming once, with the fix, rather than letting the next
/// caller rediscover it.
enum StaleGuestImageWarning {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var emitted = false

    static func emitIfNeeded(guestProtocolVersion: Int) {
        guard guestProtocolVersion < expectedGuestProtocolVersion else { return }
        lock.lock()
        let alreadyEmitted = emitted
        emitted = true
        lock.unlock()
        guard !alreadyEmitted else { return }

        FileHandle.standardError.write(Data("""
        [lumina] warning: this guest image predates protocol v\(expectedGuestProtocolVersion) \
        (agent reported v\(guestProtocolVersion)). Its init runs udhcpc, which races the \
        host network setup and can leave the VM with no IP address. Refresh with \
        `lumina pull --force`; custom images then need rebuilding from the new default.\n
        """.utf8))
    }
}
