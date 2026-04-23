// Package portfwd implements host↔guest TCP port forwarding over
// vsock. The host asks for a forward; we open a vsock listener,
// reply with its port, and proxy each accepted connection to
// 127.0.0.1:<guest_port> inside the VM.
//
// The vsock bind primitive is pluggable (see `listenFunc`) so
// Manager's core logic — port allocation, recycling, collision
// handling — is testable on any platform. The production wiring in
// `New` uses the real `vsock` package; tests inject a net.Pipe-based
// fake.
package portfwd

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// firstDynamicPort is where we start allocating. Ports below 1025 are
// reserved for the primary agent listener and future system services.
const firstDynamicPort = uint32(1025)

// maxVsockPort is the 16-bit ceiling on vsock port numbers. Past this
// we refuse to monotonically allocate; callers must wait for Stop to
// return ports to the free list.
const maxVsockPort = uint32(65535)

// dialTimeout caps how long we wait for the local service before
// dropping the proxied vsock connection.
const dialTimeout = 5 * time.Second

// listenFunc is the vsock bind primitive. Production uses vsock.Listen;
// tests inject a net.Pipe-based fake so the port-allocation and
// double-start logic can be exercised without a real kernel socket.
type listenFunc func(port int) (net.Listener, error)

// Manager tracks active forwards by guest TCP port.
type Manager struct {
	w *wire.Writer

	// listen is the vsock bind primitive. Production uses vsock.Listen;
	// tests inject a fake via NewWithListen.
	listen listenFunc

	mu             sync.Mutex
	nextVsockPort  uint32
	freeVsockPorts []uint32 // recycled from Stop; popped before nextVsockPort++
	active         map[int]*forward
}

// NewWithListen creates an empty Manager with a pluggable vsock listener
// factory. The production path is `New` which wires in `vsock.Listen`;
// tests use this form to inject a net.Pipe-based listener so the
// port-allocation and double-start paths can run on platforms that
// don't support AF_VSOCK.
func NewWithListen(w *wire.Writer, listen listenFunc) *Manager {
	return &Manager{
		w:             w,
		listen:        listen,
		nextVsockPort: firstDynamicPort,
		active:        make(map[int]*forward),
	}
}

// forward is a single active mapping.
type forward struct {
	ln        net.Listener
	cancel    context.CancelFunc
	vsockPort uint32 // captured so Stop can recycle it
}

// Start opens a vsock listener, registers it, and replies with
// port_forward_ready so the host can start accepting on the matching
// host-side local TCP socket. A double-start for an already-forwarded
// guest port emits a port_forward_error so the host can surface a
// clear message to the caller instead of timing out.
func (m *Manager) Start(guestPort int) {
	m.mu.Lock()
	if _, exists := m.active[guestPort]; exists {
		m.mu.Unlock()
		_, _ = fmt.Fprintf(os.Stderr, "port_forward: already active for guest_port=%d\n", guestPort)
		_ = m.w.Send(protocol.PortForwardErrorMsg{
			Type:      protocol.TypePortForwardError,
			GuestPort: guestPort,
			Reason:    "already active",
		})
		return
	}
	vsockPort, ok := m.allocateVsockPortLocked()
	if !ok {
		m.mu.Unlock()
		_, _ = fmt.Fprintf(os.Stderr, "port_forward: vsock port space exhausted\n")
		_ = m.w.Send(protocol.PortForwardErrorMsg{
			Type:      protocol.TypePortForwardError,
			GuestPort: guestPort,
			Reason:    "vsock port exhausted",
		})
		return
	}
	m.mu.Unlock()

	ln, err := m.listen(int(vsockPort))
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "port_forward: vsock listen on %d failed: %v\n", vsockPort, err)
		// Return the port to the free list — we never got to use it.
		m.mu.Lock()
		m.freeVsockPorts = append(m.freeVsockPorts, vsockPort)
		m.mu.Unlock()
		_ = m.w.Send(protocol.PortForwardErrorMsg{
			Type:      protocol.TypePortForwardError,
			GuestPort: guestPort,
			Reason:    fmt.Sprintf("vsock listen: %v", err),
		})
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	m.mu.Lock()
	m.active[guestPort] = &forward{ln: ln, cancel: cancel, vsockPort: vsockPort}
	m.mu.Unlock()

	// Reply BEFORE the accept goroutine launches. unix.Listen has
	// already succeeded, so accept is safe immediately — the host can
	// connect the moment it receives ready.
	_ = m.w.Send(protocol.PortForwardReadyMsg{
		Type:      protocol.TypePortForwardReady,
		GuestPort: guestPort,
		VsockPort: int(vsockPort),
	})

	go m.acceptLoop(ctx, ln, guestPort, vsockPort)
}

// Stop closes the listener, cancels the accept context, and returns
// the vsock port to the free list so a subsequent Start can reuse it.
// In-flight proxy goroutines unblock via their deferred Close calls.
// A long-running session that churns many forwards therefore stays
// bounded in vsock-port consumption instead of leaking the 16-bit
// space one port at a time.
func (m *Manager) Stop(guestPort int) {
	m.mu.Lock()
	f, ok := m.active[guestPort]
	if ok {
		delete(m.active, guestPort)
		m.freeVsockPorts = append(m.freeVsockPorts, f.vsockPort)
	}
	m.mu.Unlock()
	if !ok {
		return
	}
	// Close the listener first so Accept returns; then cancel so
	// in-flight proxy connections observe ctx.Done() and tear down.
	_ = f.ln.Close()
	f.cancel()
}

// allocateVsockPortLocked returns a vsock port to use for a new
// forward. Prefers the free list over monotonically advancing, so a
// start/stop/start cycle reuses the same port — keeps the 16-bit port
// space bounded across long-running sessions. Caller must hold m.mu.
// Returns (port, false) when both the free list is empty and the
// monotonic cursor has passed maxVsockPort.
func (m *Manager) allocateVsockPortLocked() (uint32, bool) {
	if n := len(m.freeVsockPorts); n > 0 {
		port := m.freeVsockPorts[n-1]
		m.freeVsockPorts = m.freeVsockPorts[:n-1]
		return port, true
	}
	if m.nextVsockPort > maxVsockPort {
		return 0, false
	}
	port := m.nextVsockPort
	m.nextVsockPort++
	return port, true
}

// ── private ─────────────────────────────────────────────────────────

func (m *Manager) acceptLoop(ctx context.Context, ln net.Listener, guestPort int, vsockPort uint32) {
	defer func() {
		_ = ln.Close()
		m.mu.Lock()
		// Only delete if the map entry still points at this listener —
		// guards against a stop+restart race where a later forward
		// replaced the entry.
		if cur, ok := m.active[guestPort]; ok && cur.ln == ln {
			delete(m.active, guestPort)
		}
		m.mu.Unlock()
	}()

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		vsockConn, err := ln.Accept()
		if err != nil {
			// Cancellation path: ln.Close() makes Accept return an error.
			if ctx.Err() != nil {
				return
			}
			_, _ = fmt.Fprintf(os.Stderr, "port_forward: accept on vsock %d failed: %v\n", vsockPort, err)
			return
		}
		go proxy(ctx, vsockConn, guestPort)
	}
}

// proxy bridges vsockConn ↔ 127.0.0.1:guestPort. Both ends close on
// ctx.Done() or when either side of the stream finishes.
func proxy(ctx context.Context, vsockConn net.Conn, guestPort int) {
	defer vsockConn.Close()

	tcpConn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", guestPort), dialTimeout)
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "port_forward: connect to 127.0.0.1:%d failed: %v\n", guestPort, err)
		return
	}
	defer tcpConn.Close()

	// Bidirectional copy. When either side closes, signal done so the
	// other goroutine's blocked Read unblocks via the deferred Close
	// calls above.
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(tcpConn, vsockConn); done <- struct{}{} }()
	go func() { _, _ = io.Copy(vsockConn, tcpConn); done <- struct{}{} }()

	select {
	case <-done:
		// One side closed. Defers close both ends; the surviving io.Copy
		// returns and pushes to the buffered channel (capacity 2 so it
		// won't block). We don't wait for it.
	case <-ctx.Done():
		// Forward torn down; defers close both ends.
	}
}
