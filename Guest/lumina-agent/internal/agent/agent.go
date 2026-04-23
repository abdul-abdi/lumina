// Package agent wires the per-connection dispatcher. The outermost
// layer (main.go) accepts vsock connections; for each one, we spin up
// an Agent, send ready, start a heartbeat, and run the scanner loop
// until the host disconnects.
package agent

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/bootmark"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/execmgr"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/network"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/portfwd"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/ptymgr"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/transfer"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// HeartbeatInterval is how often we ping the host. Short enough that
// a hung connection is detected quickly; long enough not to churn.
const HeartbeatInterval = 2 * time.Second

// Agent owns all per-connection state.
type Agent struct {
	conn    net.Conn
	w       *wire.Writer
	exec    *execmgr.Manager
	pty     *ptymgr.Manager
	portFwd *portfwd.Manager
}

// New builds an Agent around conn. One Agent per accepted connection.
func New(conn net.Conn) *Agent {
	w := wire.NewWriter(conn)
	return &Agent{
		conn:    conn,
		w:       w,
		exec:    execmgr.New(w),
		pty:     ptymgr.New(w),
		portFwd: portfwd.New(w),
	}
}

// Serve runs the per-connection lifecycle: ready → heartbeat → dispatch.
// Returns when the scanner errors or EOFs; all running commands get a
// chance to finish before we return.
func (a *Agent) Serve() {
	_ = a.w.Send(protocol.NewReady())
	bootmark.Mark("ready_sent")

	ctx, cancelHeartbeat := context.WithCancel(context.Background())
	defer cancelHeartbeat()
	go a.heartbeat(ctx)

	scanner := bufio.NewScanner(a.conn)
	scanner.Buffer(make([]byte, protocol.MaxChunkSize*2), protocol.MaxChunkSize*2)

	for scanner.Scan() {
		a.dispatch(scanner)
	}

	if err := scanner.Err(); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "connection error: %v\n", err)
	}

	// Drain in-flight commands before returning to the accept loop.
	a.exec.WaitAll()
}

// ── private ─────────────────────────────────────────────────────────

// dispatch routes a single scanned frame to the matching handler. Any
// decode error is logged but non-fatal — one malformed frame does not
// kill the connection.
func (a *Agent) dispatch(scanner *bufio.Scanner) {
	var env protocol.Envelope
	line := scanner.Bytes()
	if err := json.Unmarshal(line, &env); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid request: %v\n", err)
		return
	}

	switch env.Type {
	case protocol.TypeExec:
		a.handleExec(line)
	case protocol.TypeStdin:
		a.handleStdin(line)
	case protocol.TypeStdinClose:
		a.handleStdinClose(line)
	case protocol.TypeUpload:
		a.handleUpload(scanner, line)
	case protocol.TypeDownloadReq:
		a.handleDownload(line)
	case protocol.TypeCancel:
		a.handleCancel(line)
	case protocol.TypeConfigureNetwork:
		a.handleConfigureNetwork(line)
	case protocol.TypePtyExec:
		a.handlePtyExec(line)
	case protocol.TypePtyInput:
		a.handlePtyInput(line)
	case protocol.TypeWindowResize:
		a.handleWindowResize(line)
	case protocol.TypePortForwardStart:
		a.handlePortForwardStart(line)
	case protocol.TypePortForwardStop:
		a.handlePortForwardStop(line)
	default:
		_, _ = fmt.Fprintf(os.Stderr, "unexpected message type: %s\n", env.Type)
	}
}

func (a *Agent) handleExec(line []byte) {
	var req protocol.ExecRequest
	if err := json.Unmarshal(line, &req); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid exec request: %v\n", err)
		return
	}
	stdinR, stdinW, err := a.exec.Register(req.ID)
	if err != nil {
		_ = a.w.Send(protocol.OutputMsg{
			Type:   protocol.TypeOutput,
			ID:     req.ID,
			Stream: protocol.StreamStderr,
			Data:   fmt.Sprintf("failed to create stdin pipe: %v\n", err),
		})
		_ = a.w.Send(protocol.NewExit(req.ID, 127))
		return
	}
	go a.exec.Execute(req, stdinR, stdinW)
}

func (a *Agent) handleStdin(line []byte) {
	var msg protocol.StdinMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid stdin message: %v\n", err)
		return
	}
	a.exec.Stdin(msg)
}

func (a *Agent) handleStdinClose(line []byte) {
	var msg protocol.StdinCloseMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid stdin_close message: %v\n", err)
		return
	}
	a.exec.StdinClose(msg)
}

func (a *Agent) handleUpload(scanner *bufio.Scanner, line []byte) {
	var msg protocol.UploadMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_ = a.w.Send(protocol.UploadErrorMsg{
			Type:  protocol.TypeUploadError,
			Error: err.Error(),
		})
		return
	}
	transfer.HandleUpload(a.w, scanner, msg)
}

func (a *Agent) handleDownload(line []byte) {
	var msg protocol.DownloadReqMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_ = a.w.Send(protocol.DownloadErrorMsg{
			Type:  protocol.TypeDownloadError,
			Error: err.Error(),
		})
		return
	}
	transfer.HandleDownload(a.w, msg)
}

func (a *Agent) handleCancel(line []byte) {
	var msg protocol.CancelMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid cancel request: %v\n", err)
		return
	}
	a.exec.Cancel(msg)
}

func (a *Agent) handleConfigureNetwork(line []byte) {
	var msg protocol.ConfigureNetworkMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid configure_network request: %v\n", err)
		return
	}
	// Network config is synchronous-ish (polls carrier for up to 2 s)
	// so hand it off to a goroutine — we don't want to block the
	// message loop on link readiness.
	go network.Configure(a.w, msg)
}

func (a *Agent) handlePtyExec(line []byte) {
	var req protocol.PtyExecRequest
	if err := json.Unmarshal(line, &req); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid pty_exec request: %v\n", err)
		return
	}
	if a.pty.HasActive(req.ID) {
		_ = a.w.Send(protocol.PtyOutputMsg{
			Type: protocol.TypePtyOutput,
			ID:   req.ID,
			Data: base64.StdEncoding.EncodeToString([]byte("pty session already active for this ID\r\n")),
		})
		_ = a.w.Send(protocol.NewExit(req.ID, 1))
		return
	}
	go a.pty.Execute(req)
}

func (a *Agent) handlePtyInput(line []byte) {
	var msg protocol.PtyInputMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid pty_input: %v\n", err)
		return
	}
	a.pty.Input(msg)
}

func (a *Agent) handleWindowResize(line []byte) {
	var msg protocol.WindowResizeMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid window_resize: %v\n", err)
		return
	}
	a.pty.Resize(msg)
}

func (a *Agent) handlePortForwardStart(line []byte) {
	var msg protocol.PortForwardStartMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid port_forward_start: %v\n", err)
		return
	}
	// Listener creation is fast but we keep it off the message loop so
	// a slow allocator doesn't block unrelated frames.
	go a.portFwd.Start(msg.GuestPort)
}

func (a *Agent) handlePortForwardStop(line []byte) {
	var msg protocol.PortForwardStopMsg
	if err := json.Unmarshal(line, &msg); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid port_forward_stop: %v\n", err)
		return
	}
	a.portFwd.Stop(msg.GuestPort)
}

// heartbeat pings the host every HeartbeatInterval. A write failure
// means the connection dropped — kill all running commands so the
// outer accept loop can reclaim resources fast.
func (a *Agent) heartbeat(ctx context.Context) {
	ticker := time.NewTicker(HeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := a.w.Send(protocol.NewHeartbeat()); err != nil {
				a.exec.KillAll()
				a.pty.KillAll()
				return
			}
		}
	}
}

