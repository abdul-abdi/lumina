// Package protocol defines the NDJSON wire types exchanged between the
// host (Swift library) and the guest agent. Every message carries a
// `type` discriminator; the host dispatches on it.
//
// Keep this file purely declarative — no behaviour, no I/O. It is
// imported by every other internal package and by the host-side test
// suite (via the fixture golden bytes).
package protocol

// ── Wire-level constants ────────────────────────────────────────────

const (
	// MaxChunkSize is the ceiling on a single NDJSON frame. Matches
	// the host-side SessionServer limit and the Swift ProtocolTests
	// expectations.
	MaxChunkSize = 65536 // 64 KiB
)

// Type discriminators. Keep in one place so typos are a compile error,
// not a runtime dispatch miss.
const (
	TypeReady            = "ready"
	TypeHeartbeat        = "heartbeat"
	TypeExec             = "exec"
	TypeOutput           = "output"
	TypeExit             = "exit"
	TypeStdin            = "stdin"
	TypeStdinClose       = "stdin_close"
	TypeCancel           = "cancel"
	TypeConfigureNetwork = "configure_network"
	TypeNetworkReady     = "network_ready"
	TypeNetworkError     = "network_error"
	TypeNetworkMetrics   = "network_metrics"

	TypeUpload        = "upload"
	TypeUploadAck     = "upload_ack"
	TypeUploadError   = "upload_error"
	TypeUploadDone    = "upload_done"
	TypeDownloadReq   = "download_req"
	TypeDownloadData  = "download_data"
	TypeDownloadError = "download_error"

	TypePtyExec      = "pty_exec"
	TypePtyInput     = "pty_input"
	TypePtyOutput    = "pty_output"
	TypeWindowResize = "window_resize"

	TypePortForwardStart = "port_forward_start"
	TypePortForwardStop  = "port_forward_stop"
	TypePortForwardReady = "port_forward_ready"
	TypePortForwardError = "port_forward_error"
)

// Stream names used in OutputMsg.
const (
	StreamStdout = "stdout"
	StreamStderr = "stderr"
)

// Envelope is the minimal header used to peek at the Type before
// decoding into a concrete struct.
type Envelope struct {
	Type string `json:"type"`
}

// ── Host → guest messages ──────────────────────────────────────────

type ExecRequest struct {
	Type    string            `json:"type"`
	ID      string            `json:"id"`
	Cmd     string            `json:"cmd"`
	Timeout int               `json:"timeout"`
	Env     map[string]string `json:"env"`
	Cwd     string            `json:"cwd,omitempty"`
}

type StdinMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Data string `json:"data"`
}

type StdinCloseMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

type CancelMsg struct {
	Type        string `json:"type"`
	ID          string `json:"id,omitempty"`
	Signal      int    `json:"signal"`
	GracePeriod int    `json:"grace_period"`
}

type ConfigureNetworkMsg struct {
	Type    string `json:"type"`
	IP      string `json:"ip"`
	Gateway string `json:"gateway"`
	DNS     string `json:"dns"`
}

type UploadMsg struct {
	Type string `json:"type"`
	Path string `json:"path"`
	Data string `json:"data"`
	Mode string `json:"mode"`
	Seq  int    `json:"seq"`
	Eof  bool   `json:"eof"`
}

type DownloadReqMsg struct {
	Type string `json:"type"`
	Path string `json:"path"`
}

type PtyExecRequest struct {
	Type    string            `json:"type"`
	ID      string            `json:"id"`
	Cmd     string            `json:"cmd"`
	Timeout int               `json:"timeout"`
	Env     map[string]string `json:"env"`
	Cols    int               `json:"cols"`
	Rows    int               `json:"rows"`
}

type PtyInputMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Data string `json:"data"`
}

type WindowResizeMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Cols int    `json:"cols"`
	Rows int    `json:"rows"`
}

type PortForwardStartMsg struct {
	Type      string `json:"type"`
	GuestPort int    `json:"guest_port"`
}

type PortForwardStopMsg struct {
	Type      string `json:"type"`
	GuestPort int    `json:"guest_port"`
}

// ── Guest → host messages ──────────────────────────────────────────

// ProtocolVersion is the wire-format version this agent speaks.
// Bump on any breaking wire change so the host can branch cleanly
// (or refuse to talk to a too-old/too-new agent) instead of
// guessing from message-shape probing. Old agents predate this
// field and the host treats absence as version=0.
const ProtocolVersion = 1

// AgentCapabilities is the conservative list of message families
// this build of the agent implements. The host may consult it
// before issuing a `pty_exec` or `port_forward_start` against an
// older guest. Adding a capability is non-breaking (older hosts
// ignore unknown strings); removing one IS breaking and must be
// paired with a ProtocolVersion bump.
var AgentCapabilities = []string{
	"pty",              // pty_exec / pty_input / pty_output / window_resize
	"port_forward",     // port_forward_start / stop / ready / error
	"network_metrics",  // periodic network_metrics frames
	"network_error",    // typed network_error on configure_network failure
	"binary_output",    // base64-encoded output for non-UTF-8 chunks
	"configure_network",
	"stdin",
}

type ReadyMsg struct {
	Type            string   `json:"type"`
	ProtocolVersion int      `json:"protocol_version,omitempty"`
	Capabilities    []string `json:"capabilities,omitempty"`
}

func NewReady() ReadyMsg {
	return ReadyMsg{
		Type:            TypeReady,
		ProtocolVersion: ProtocolVersion,
		Capabilities:    AgentCapabilities,
	}
}

type HeartbeatMsg struct {
	Type string `json:"type"`
}

func NewHeartbeat() HeartbeatMsg { return HeartbeatMsg{Type: TypeHeartbeat} }

type OutputMsg struct {
	Type     string `json:"type"`
	ID       string `json:"id"`
	Stream   string `json:"stream"`
	Data     string `json:"data"`
	Encoding string `json:"encoding,omitempty"` // "base64" for non-UTF-8 binary chunks; absent for text
}

type ExitMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Code int    `json:"code"`
}

func NewExit(id string, code int) ExitMsg {
	return ExitMsg{Type: TypeExit, ID: id, Code: code}
}

type NetworkReadyMsg struct {
	Type string `json:"type"`
	IP   string `json:"ip"`
	// ConfigMs is the wall-clock time from configure_network receipt
	// to network_ready emission on the guest. Host uses this to
	// populate BootPhases.networkReadyMs without round-trip jitter
	// contaminating the measurement.
	ConfigMs int `json:"config_ms,omitempty"`
	// Stage annotates which readiness gate fired: "operstate",
	// "carrier", "route-verified", or "timeout-anyway". "timeout-
	// anyway" means the guest shipped network_ready on the
	// defensive fallback; host should treat this as a warning
	// signal, not a hard guarantee. Absent on pre-v0.7.1 agents.
	Stage string `json:"stage,omitempty"`
}

// InterfaceCounters is the per-NIC counter snapshot shipped inside
// NetworkMetricsMsg. Values are cumulative since interface-up, read
// straight from /proc/net/dev — the same numbers `ifconfig`/`ip -s`
// would show. Hosts compute deltas themselves if they want per-
// interval throughput.
type InterfaceCounters struct {
	RxBytes   uint64 `json:"rx_bytes"`
	TxBytes   uint64 `json:"tx_bytes"`
	RxErrors  uint64 `json:"rx_errors"`
	TxErrors  uint64 `json:"tx_errors"`
	RxPackets uint64 `json:"rx_packets"`
	TxPackets uint64 `json:"tx_packets"`
}

// NetworkMetricsMsg is a periodic snapshot of guest-side network
// counters. The map-shaped `interfaces` field is intentional: multi-
// NIC VMs are a foreseeable future, and renaming a singular `iface`
// field later would break the protocol. `lo` is excluded — consumers
// care about externally-visible traffic, not loopback.
type NetworkMetricsMsg struct {
	Type       string                       `json:"type"`
	Interfaces map[string]InterfaceCounters `json:"interfaces"`
}

// NetworkErrorMsg signals the guest failed to bring up the network.
// Sent when the `ip -batch` command failed AND the individual retry
// attempts also failed — the interface is unusable. Host propagates
// this to the waiting configureNetwork() caller as a typed error.
// Distinct from "timeout-anyway" which means network_ready fired on
// a softer guarantee; NetworkErrorMsg means the setup itself broke.
type NetworkErrorMsg struct {
	Type   string `json:"type"`
	Reason string `json:"reason"`
	// Attempts is how many retries the guest made before giving up.
	// Diagnostic only; host uses it for log prefix, not for retry
	// logic.
	Attempts int `json:"attempts,omitempty"`
}

type UploadAckMsg struct {
	Type string `json:"type"`
	Seq  int    `json:"seq"`
}

type UploadErrorMsg struct {
	Type  string `json:"type"`
	Path  string `json:"path"`
	Error string `json:"error"`
}

type UploadDoneMsg struct {
	Type string `json:"type"`
	Path string `json:"path"`
}

type DownloadDataMsg struct {
	Type string `json:"type"`
	Path string `json:"path"`
	Data string `json:"data"`
	Seq  int    `json:"seq"`
	Eof  bool   `json:"eof"`
}

type DownloadErrorMsg struct {
	Type  string `json:"type"`
	Path  string `json:"path"`
	Error string `json:"error"`
}

type PtyOutputMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Data string `json:"data"`
}

type PortForwardReadyMsg struct {
	Type      string `json:"type"`
	GuestPort int    `json:"guest_port"`
	VsockPort int    `json:"vsock_port"`
}

// PortForwardErrorMsg signals the guest couldn't establish a forward.
// Sent in response to a PortForwardStartMsg that collided with an
// existing forward on the same guest port, or when the guest-side
// vsock bind failed. The host dispatches this to the pending
// portForwardContinuation and surfaces the reason to the caller.
//
// Reasons are human-readable strings — callers should not parse them,
// they are for logs and error messages. Well-known values today:
//   - "already active"    : host sent start twice for the same port
//   - "vsock listen"      : guest-side vsock bind failed
type PortForwardErrorMsg struct {
	Type      string `json:"type"`
	GuestPort int    `json:"guest_port"`
	Reason    string `json:"reason"`
}
