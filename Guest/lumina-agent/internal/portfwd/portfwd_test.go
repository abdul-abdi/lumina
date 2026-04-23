// Tests for the platform-neutral core of portfwd.Manager.
// These exercise port allocation, recycling, and the double-start
// collision path without requiring AF_VSOCK — the production vsock
// bind is injected as `listenFunc`, defaulted to a net.Pipe-based
// fake in the test harness below.
package portfwd

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// fakeListener satisfies net.Listener with a channel-backed Accept so
// it can be closed without dangling goroutines. The acceptCh stays
// empty in these tests — we never drive accepts through.
type fakeListener struct {
	mu       sync.Mutex
	closed   bool
	acceptCh chan net.Conn
}

func newFakeListener() *fakeListener {
	return &fakeListener{acceptCh: make(chan net.Conn)}
}

func (l *fakeListener) Accept() (net.Conn, error) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil, errors.New("listener closed")
	}
	ch := l.acceptCh
	l.mu.Unlock()
	conn, ok := <-ch
	if !ok {
		return nil, errors.New("listener closed")
	}
	return conn, nil
}

func (l *fakeListener) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	close(l.acceptCh)
	return nil
}

func (l *fakeListener) Addr() net.Addr { return fakeAddr{} }

type fakeAddr struct{}

func (fakeAddr) Network() string { return "fake" }
func (fakeAddr) String() string  { return "fake" }

// harness packages a Manager + a tailing goroutine that collects the
// NDJSON frames the Manager emits through its wire.Writer. `drainN`
// reads exactly N messages with a deadline, so tests fail fast if the
// Manager never writes.
type harness struct {
	mgr       *Manager
	messages  chan map[string]any
	listenLog []int // every vsock port the manager asked to bind
}

func newHarness(t *testing.T) *harness {
	t.Helper()

	hostConn, guestConn := net.Pipe()
	t.Cleanup(func() {
		_ = hostConn.Close()
		_ = guestConn.Close()
	})

	w := wire.NewWriter(guestConn)
	h := &harness{
		messages: make(chan map[string]any, 16),
	}
	h.mgr = NewWithListen(w, func(port int) (net.Listener, error) {
		h.listenLog = append(h.listenLog, port)
		return newFakeListener(), nil
	})

	// Tailing goroutine: decode NDJSON off hostConn into the channel.
	go func() {
		scanner := bufio.NewScanner(hostConn)
		scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
		for scanner.Scan() {
			var msg map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				return
			}
			select {
			case h.messages <- msg:
			case <-time.After(2 * time.Second):
				return
			}
		}
	}()

	return h
}

func (h *harness) next(t *testing.T) map[string]any {
	t.Helper()
	select {
	case msg := <-h.messages:
		return msg
	case <-time.After(2 * time.Second):
		t.Fatalf("no message from manager within 2s")
		return nil
	}
}

func (h *harness) expectType(t *testing.T, want string) map[string]any {
	t.Helper()
	msg := h.next(t)
	if got, _ := msg["type"].(string); got != want {
		t.Fatalf("expected type=%q, got %v (full: %v)", want, got, msg)
	}
	return msg
}

func (h *harness) expectNoMessage(t *testing.T, within time.Duration) {
	t.Helper()
	select {
	case msg := <-h.messages:
		t.Fatalf("expected no message, got %v", msg)
	case <-time.After(within):
	}
}

// ── allocation + recycling ──────────────────────────────────────────

func TestStart_AllocatesFromDynamicPortPool(t *testing.T) {
	h := newHarness(t)

	h.mgr.Start(3000)
	msg := h.expectType(t, protocol.TypePortForwardReady)

	if got := msg["guest_port"]; got != float64(3000) {
		t.Fatalf("expected guest_port=3000, got %v", got)
	}
	if got := msg["vsock_port"]; got != float64(firstDynamicPort) {
		t.Fatalf("expected vsock_port=%d, got %v", firstDynamicPort, got)
	}
}

func TestStart_AllocationMonotonicAcrossStarts(t *testing.T) {
	h := newHarness(t)

	for i, guestPort := range []int{3000, 3001, 3002} {
		h.mgr.Start(guestPort)
		msg := h.expectType(t, protocol.TypePortForwardReady)
		want := float64(int(firstDynamicPort) + i)
		if got := msg["vsock_port"]; got != want {
			t.Fatalf("start #%d: expected vsock_port=%v, got %v", i, want, got)
		}
	}
}

func TestStop_RecyclesVsockPort(t *testing.T) {
	h := newHarness(t)

	// Start forward #1 → allocates firstDynamicPort.
	h.mgr.Start(3000)
	msg := h.expectType(t, protocol.TypePortForwardReady)
	first := int(msg["vsock_port"].(float64))

	// Stop returns that port to the free list.
	h.mgr.Stop(3000)

	// A subsequent Start reuses the port instead of advancing the
	// monotonic cursor — the whole point of recycling, otherwise
	// 65k start/stop cycles exhaust the space.
	h.mgr.Start(3001)
	msg2 := h.expectType(t, protocol.TypePortForwardReady)
	reused := int(msg2["vsock_port"].(float64))

	if reused != first {
		t.Fatalf("recycled start expected vsock_port=%d (reused), got %d",
			first, reused)
	}
}

func TestStop_IsNoopOnUnknownPort(t *testing.T) {
	h := newHarness(t)

	// Stop without a matching Start must not panic and must not
	// emit a message. (Idempotency — the host retries stop on
	// error paths.)
	h.mgr.Stop(9999)
	h.expectNoMessage(t, 50*time.Millisecond)
}

func TestAllocateVsockPort_PrefersFreeList(t *testing.T) {
	h := newHarness(t)

	// Force the free list to have a stale-looking lower-numbered
	// port. Allocation must prefer it over nextVsockPort.
	h.mgr.mu.Lock()
	h.mgr.freeVsockPorts = append(h.mgr.freeVsockPorts, firstDynamicPort+100)
	h.mgr.mu.Unlock()

	h.mgr.Start(3000)
	msg := h.expectType(t, protocol.TypePortForwardReady)
	if got := int(msg["vsock_port"].(float64)); got != int(firstDynamicPort+100) {
		t.Fatalf("expected recycled port %d, got %d", firstDynamicPort+100, got)
	}
}

// ── double-start collision ──────────────────────────────────────────

func TestStart_DoubleStartEmitsError(t *testing.T) {
	h := newHarness(t)

	h.mgr.Start(3000)
	h.expectType(t, protocol.TypePortForwardReady)

	// Second start on the same guest port must NOT silently drop
	// and must NOT mutate the existing forward's state. It must
	// emit a port_forward_error so the host can fail the caller's
	// continuation with a clear reason.
	h.mgr.Start(3000)
	errMsg := h.expectType(t, protocol.TypePortForwardError)

	if got := errMsg["guest_port"]; got != float64(3000) {
		t.Fatalf("expected guest_port=3000, got %v", got)
	}
	reason, _ := errMsg["reason"].(string)
	if !strings.Contains(reason, "already active") {
		t.Fatalf("expected reason contains 'already active', got %q", reason)
	}
}

// ── listen-failure path returns the vsock port to the free list ─────

func TestStart_ListenFailureReturnsPortToFreeList(t *testing.T) {
	hostConn, guestConn := net.Pipe()
	t.Cleanup(func() {
		_ = hostConn.Close()
		_ = guestConn.Close()
	})
	w := wire.NewWriter(guestConn)

	// A failing listen returns error; Manager should emit
	// port_forward_error AND return the port to the free list so
	// the next Start doesn't skip the slot forever.
	var attempted []int
	var failNext = true
	mgr := NewWithListen(w, func(port int) (net.Listener, error) {
		attempted = append(attempted, port)
		if failNext {
			return nil, errors.New("simulated listen failure")
		}
		return newFakeListener(), nil
	})

	// Drain the error frame off hostConn in the background so the
	// wire.Writer doesn't block.
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = io.ReadAll(hostConn) // drain until pipe closes
	}()

	mgr.Start(3000)

	failNext = false
	mgr.Start(3001)

	// Two attempts, both at the same low port — the failed first
	// start returned its allocation.
	if len(attempted) != 2 {
		t.Fatalf("expected 2 listen attempts, got %d", len(attempted))
	}
	if attempted[0] != attempted[1] {
		t.Fatalf("expected second attempt to reuse port %d, got %d",
			attempted[0], attempted[1])
	}
}
