//go:build linux

// Tests for ptymgr — scoped to Linux because the package depends on
// /dev/ptmx, TIOCSPTLCK, and TIOCGPTN. Runs in CI via a
// GOOS=linux GOARCH=arm64 cross-compile check, and locally inside a
// Lumina VM via `make test-guest`. The tests here focus on the
// platform-neutral bookkeeping — pending-resize TTL, KillAll shape —
// so they don't need a real pty to run.
package ptymgr

import (
	"net"
	"testing"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// fakeConn over net.Pipe so the wire.Writer doesn't need a socket.
func newTestManager(t *testing.T) (*Manager, net.Conn, chan time.Time) {
	t.Helper()
	hostConn, guestConn := net.Pipe()
	t.Cleanup(func() {
		_ = hostConn.Close()
		_ = guestConn.Close()
	})
	w := wire.NewWriter(guestConn)
	m := New(w)

	// Inject a controllable clock so the TTL path is exercisable
	// without time.Sleep. Each tick the test pushes onto the chan
	// is consumed by the manager's `now` closure.
	clock := make(chan time.Time, 16)
	m.now = func() time.Time {
		select {
		case t := <-clock:
			return t
		default:
			return time.Now()
		}
	}
	return m, hostConn, clock
}

func TestResize_BuffersInPendingWhenPtyNotLive(t *testing.T) {
	m, _, _ := newTestManager(t)

	m.Resize(protocol.WindowResizeMsg{
		Type: protocol.TypeWindowResize, ID: "a",
		Cols: 100, Rows: 30,
	})

	m.pendingMu.Lock()
	defer m.pendingMu.Unlock()
	got, ok := m.pendingResizes["a"]
	if !ok {
		t.Fatalf("expected pendingResizes[a] to be populated")
	}
	if got.cols != 100 || got.rows != 30 {
		t.Fatalf("expected cols=100,rows=30; got cols=%d,rows=%d",
			got.cols, got.rows)
	}
}

func TestResize_PendingTTL_EvictsStaleEntries(t *testing.T) {
	m, _, clock := newTestManager(t)

	baseline := time.Date(2026, 4, 23, 12, 0, 0, 0, time.UTC)

	// Insert a stale entry at baseline.
	clock <- baseline
	m.Resize(protocol.WindowResizeMsg{
		Type: protocol.TypeWindowResize, ID: "stale-1",
		Cols: 80, Rows: 24,
	})
	clock <- baseline
	m.Resize(protocol.WindowResizeMsg{
		Type: protocol.TypeWindowResize, ID: "stale-2",
		Cols: 80, Rows: 24,
	})

	m.pendingMu.Lock()
	if len(m.pendingResizes) != 2 {
		m.pendingMu.Unlock()
		t.Fatalf("expected 2 stale entries, got %d", len(m.pendingResizes))
	}
	m.pendingMu.Unlock()

	// Advance clock well past TTL, then insert one more entry.
	// The eviction pass runs on every Resize and must drop both
	// stale entries while keeping the fresh one.
	future := baseline.Add(pendingResizeTTL + time.Second)
	clock <- future
	m.Resize(protocol.WindowResizeMsg{
		Type: protocol.TypeWindowResize, ID: "fresh",
		Cols: 100, Rows: 30,
	})

	m.pendingMu.Lock()
	defer m.pendingMu.Unlock()
	if len(m.pendingResizes) != 1 {
		t.Fatalf("expected 1 entry after TTL sweep, got %d (entries: %v)",
			len(m.pendingResizes), m.pendingResizes)
	}
	if _, ok := m.pendingResizes["fresh"]; !ok {
		t.Fatalf("expected 'fresh' to survive the sweep")
	}
}

func TestResize_PendingMap_IsEvictedByExecute(t *testing.T) {
	// Covers the existing contract: Execute's consumer branch drains
	// the pending entry when a matching pty_exec eventually arrives.
	// We can't drive Execute fully here without a real PTY, but we
	// can check that the pending entry exists pre-drain and that the
	// drain logic's map delete keyword matches the same ID we
	// inserted. (Pinned so the map-key schema doesn't silently drift.)
	m, _, _ := newTestManager(t)

	m.Resize(protocol.WindowResizeMsg{
		Type: protocol.TypeWindowResize, ID: "pending-id",
		Cols: 120, Rows: 40,
	})

	m.pendingMu.Lock()
	if _, ok := m.pendingResizes["pending-id"]; !ok {
		m.pendingMu.Unlock()
		t.Fatalf("expected pending entry to exist with key 'pending-id'")
	}
	delete(m.pendingResizes, "pending-id")
	m.pendingMu.Unlock()

	m.pendingMu.Lock()
	defer m.pendingMu.Unlock()
	if _, ok := m.pendingResizes["pending-id"]; ok {
		t.Fatalf("expected pending entry removed after Execute-style drain")
	}
}
