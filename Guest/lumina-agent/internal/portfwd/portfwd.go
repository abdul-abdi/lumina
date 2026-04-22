// Package portfwd implements host↔guest TCP port forwarding over
// vsock. The host asks for a forward; we open a vsock listener,
// reply with its port, and proxy each accepted connection to
// 127.0.0.1:<guest_port> inside the VM.
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
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/vsock"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// firstDynamicPort is where we start allocating. Ports below 1025 are
// reserved for the primary agent listener and future system services.
const firstDynamicPort = uint32(1025)

// dialTimeout caps how long we wait for the local service before
// dropping the proxied vsock connection.
const dialTimeout = 5 * time.Second

// Manager tracks active forwards by guest TCP port.
type Manager struct {
	w *wire.Writer

	mu            sync.Mutex
	nextVsockPort uint32
	active        map[int]*forward
}

// New creates an empty Manager.
func New(w *wire.Writer) *Manager {
	return &Manager{
		w:             w,
		nextVsockPort: firstDynamicPort,
		active:        make(map[int]*forward),
	}
}

// forward is a single active mapping.
type forward struct {
	ln     net.Listener
	cancel context.CancelFunc
}

// Start opens a vsock listener, registers it, and replies with
// port_forward_ready so the host can start accepting on the matching
// host-side local TCP socket.
func (m *Manager) Start(guestPort int) {
	m.mu.Lock()
	if _, exists := m.active[guestPort]; exists {
		m.mu.Unlock()
		_, _ = fmt.Fprintf(os.Stderr, "port_forward: already active for guest_port=%d\n", guestPort)
		return
	}
	vsockPort := m.nextVsockPort
	m.nextVsockPort++
	m.mu.Unlock()

	ln, err := vsock.Listen(int(vsockPort))
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "port_forward: vsock listen on %d failed: %v\n", vsockPort, err)
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	m.mu.Lock()
	m.active[guestPort] = &forward{ln: ln, cancel: cancel}
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

// Stop closes the listener and cancels the accept context. In-flight
// proxy goroutines unblock via their deferred Close calls.
func (m *Manager) Stop(guestPort int) {
	m.mu.Lock()
	f, ok := m.active[guestPort]
	if ok {
		delete(m.active, guestPort)
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
