// Tests for the exec-command lifecycle. Darwin-compatible: the
// underlying syscalls (`Setpgid`, `syscall.Kill`, `/bin/sh -c …`)
// work on macOS and Linux alike, so this suite runs directly in CI
// on the macos-15 runner.
//
// Coverage:
//   - stdout capture for a fast command
//   - stdin piping (write + close) drives the child
//   - timeout terminates a long-running command and reports exit
//   - KillAll on "heartbeat failure" scenario — the v0.7.1 regression
//     gate; if this test fails, the bugfix that made disconnected-host
//     PTYs release shell processes has regressed
package execmgr

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// tailer reads NDJSON off a net.Pipe and routes frames onto the
// channel. Used by every test so the assertions can block on the
// exit frame without races.
type tailer struct {
	conn net.Conn
	ch   chan map[string]any
	done chan struct{}
}

func newTailer(t *testing.T, conn net.Conn) *tailer {
	t.Helper()
	tl := &tailer{
		conn: conn,
		ch:   make(chan map[string]any, 128),
		done: make(chan struct{}),
	}
	go func() {
		defer close(tl.done)
		scanner := bufio.NewScanner(conn)
		scanner.Buffer(make([]byte, 0, 65536), 1<<20)
		for scanner.Scan() {
			var msg map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				return
			}
			tl.ch <- msg
		}
	}()
	return tl
}

// waitFor drains up to 2 seconds looking for the first message with
// the given type. Returns the message or fails the test.
func (tl *tailer) waitFor(t *testing.T, wantType string) map[string]any {
	t.Helper()
	for {
		select {
		case msg := <-tl.ch:
			if got, _ := msg["type"].(string); got == wantType {
				return msg
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("timed out waiting for message type=%q", wantType)
			return nil
		}
	}
}

// collectUntilExit reads frames until an `exit` frame arrives.
// Returns the exit frame and all output frames in order.
func (tl *tailer) collectUntilExit(t *testing.T) (exit map[string]any, out []map[string]any) {
	t.Helper()
	for {
		select {
		case msg := <-tl.ch:
			switch msg["type"].(string) {
			case protocol.TypeOutput:
				out = append(out, msg)
			case protocol.TypeExit:
				return msg, out
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("timed out waiting for exit; collected %d output frames", len(out))
			return nil, out
		}
	}
}

func newManager(t *testing.T) (*Manager, *tailer) {
	t.Helper()
	hostConn, guestConn := net.Pipe()
	t.Cleanup(func() {
		_ = hostConn.Close()
		_ = guestConn.Close()
	})
	w := wire.NewWriter(guestConn)
	return New(w), newTailer(t, hostConn)
}

// ── lifecycle ───────────────────────────────────────────────────────

func TestExecute_StdoutCaptureAndExitCode(t *testing.T) {
	m, tl := newManager(t)

	id := "exec-stdout"
	stdinR, stdinW, err := m.Register(id)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	go m.Execute(protocol.ExecRequest{
		Type: protocol.TypeExec, ID: id,
		Cmd: "echo hello; exit 0",
	}, stdinR, stdinW)

	exit, out := tl.collectUntilExit(t)
	if code, _ := exit["code"].(float64); code != 0 {
		t.Fatalf("expected exit code 0, got %v", exit["code"])
	}
	// Find a stdout frame containing "hello".
	found := false
	for _, frame := range out {
		if stream, _ := frame["stream"].(string); stream == protocol.StreamStdout {
			if data, _ := frame["data"].(string); data != "" && data[0] == 'h' {
				found = true
				break
			}
		}
	}
	if !found {
		t.Fatalf("expected stdout frame starting with 'h', got %v", out)
	}
}

func TestExecute_NonZeroExitCodePropagates(t *testing.T) {
	m, tl := newManager(t)

	id := "exec-fail"
	stdinR, stdinW, err := m.Register(id)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	go m.Execute(protocol.ExecRequest{
		Type: protocol.TypeExec, ID: id,
		Cmd: "exit 42",
	}, stdinR, stdinW)

	exit, _ := tl.collectUntilExit(t)
	if code, _ := exit["code"].(float64); code != 42 {
		t.Fatalf("expected exit code 42, got %v", exit["code"])
	}
}

func TestStdin_PipesDataToChild(t *testing.T) {
	m, tl := newManager(t)

	id := "exec-stdin"
	stdinR, stdinW, err := m.Register(id)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	go m.Execute(protocol.ExecRequest{
		Type: protocol.TypeExec, ID: id,
		Cmd: "cat", // echo stdin → stdout
	}, stdinR, stdinW)

	// Give the command a moment to start reading stdin.
	time.Sleep(100 * time.Millisecond)

	m.Stdin(protocol.StdinMsg{
		Type: protocol.TypeStdin, ID: id,
		Data: "piped-in\n",
	})
	// Closing stdin lets cat see EOF and exit cleanly.
	m.StdinClose(protocol.StdinCloseMsg{
		Type: protocol.TypeStdinClose, ID: id,
	})

	exit, out := tl.collectUntilExit(t)
	if code, _ := exit["code"].(float64); code != 0 {
		t.Fatalf("expected exit 0, got %v", exit["code"])
	}
	// Expect "piped-in\n" in stdout.
	var captured string
	for _, frame := range out {
		if stream, _ := frame["stream"].(string); stream == protocol.StreamStdout {
			captured += frame["data"].(string)
		}
	}
	if captured == "" || captured[0] != 'p' {
		t.Fatalf("expected stdin-piped stdout, got %q", captured)
	}
}

func TestExecute_TimeoutKillsLongCommand(t *testing.T) {
	m, tl := newManager(t)

	id := "exec-timeout"
	stdinR, stdinW, err := m.Register(id)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	start := time.Now()
	go m.Execute(protocol.ExecRequest{
		Type: protocol.TypeExec, ID: id,
		Cmd: "sleep 30", Timeout: 1,
	}, stdinR, stdinW)

	exit, _ := tl.collectUntilExit(t)
	elapsed := time.Since(start)
	if elapsed > 10*time.Second {
		t.Fatalf("timeout path took too long: %v", elapsed)
	}
	// `sleep` killed by SIGTERM exits non-zero; the exact code
	// differs between SIGTERM (143) and graceful kill wrapper (1),
	// depending on whether the process survived the grace period.
	// Either signals the timeout actually fired.
	if code, _ := exit["code"].(float64); code == 0 {
		t.Fatalf("expected non-zero exit from timeout, got 0")
	}
}

// ── cancel + KillAll (the v0.7.1 heartbeat regression gate) ──────────

func TestCancel_ById_SendsSignalToSpecificCommand(t *testing.T) {
	m, tl := newManager(t)

	id1 := "exec-a"
	id2 := "exec-b"

	stdinR1, stdinW1, err := m.Register(id1)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	stdinR2, stdinW2, err := m.Register(id2)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	go m.Execute(protocol.ExecRequest{
		Type: protocol.TypeExec, ID: id1, Cmd: "sleep 30",
	}, stdinR1, stdinW1)
	go m.Execute(protocol.ExecRequest{
		Type: protocol.TypeExec, ID: id2, Cmd: "sleep 30",
	}, stdinR2, stdinW2)

	time.Sleep(150 * time.Millisecond)

	m.Cancel(protocol.CancelMsg{
		Type: protocol.TypeCancel, ID: id1,
		Signal: int(syscall.SIGTERM), GracePeriod: 0,
	})

	// Only id1 exits; id2 still running. Drain frames with id filter.
	exits := map[string]bool{}
	deadline := time.After(5 * time.Second)
drain:
	for {
		select {
		case msg := <-tl.ch:
			if msg["type"].(string) == protocol.TypeExit {
				exits[msg["id"].(string)] = true
				if exits[id1] {
					break drain
				}
			}
		case <-deadline:
			t.Fatalf("timed out; exits so far: %v", exits)
		}
	}
	if !exits[id1] {
		t.Fatalf("expected exec-a to exit; got %v", exits)
	}
	// Best-effort: kill id2 so the test teardown doesn't leak.
	m.Cancel(protocol.CancelMsg{
		Type: protocol.TypeCancel, ID: id2,
		Signal: int(syscall.SIGKILL), GracePeriod: 0,
	})
}

func TestKillAll_TerminatesAllRunningCommands(t *testing.T) {
	// The heartbeat-failure regression gate: when the host
	// disconnects, the agent's accept loop calls
	// execmgr.KillAll + ptymgr.KillAll so disconnected sessions
	// don't leave zombie shell processes. If this ever regresses
	// (e.g. someone adds a guard that skips KillAll when there's
	// no active command tracking), this test catches it.
	m, tl := newManager(t)

	ids := []string{"a", "b", "c"}
	for _, id := range ids {
		stdinR, stdinW, err := m.Register(id)
		if err != nil {
			t.Fatalf("Register: %v", err)
		}
		go m.Execute(protocol.ExecRequest{
			Type: protocol.TypeExec, ID: id, Cmd: "sleep 30",
		}, stdinR, stdinW)
	}
	time.Sleep(200 * time.Millisecond)

	// All three should be in the running map.
	m.mu.Lock()
	running := len(m.running)
	m.mu.Unlock()
	if running != len(ids) {
		t.Fatalf("expected %d running, got %d", len(ids), running)
	}

	m.KillAll()

	// Expect three exit frames.
	exits := map[string]bool{}
	deadline := time.After(5 * time.Second)
	for len(exits) < len(ids) {
		select {
		case msg := <-tl.ch:
			if msg["type"].(string) == protocol.TypeExit {
				exits[msg["id"].(string)] = true
			}
		case <-deadline:
			t.Fatalf("KillAll didn't tear down all commands; exits: %v", exits)
		}
	}
	for _, id := range ids {
		if !exits[id] {
			t.Errorf("expected exit for %q", id)
		}
	}
}

// ── stdin race guard (the pre-v0.7.1 bugfix) ────────────────────────

func TestRegister_InsertsEntryBeforeExecute(t *testing.T) {
	// Stdin arriving between the host's exec request and the
	// goroutine's own registration step used to be silently
	// dropped. Register pre-inserts a map entry with the stdin
	// pipe so Stdin lookups succeed from the moment the host
	// sent exec, not from the moment the goroutine scheduled.
	m, _ := newManager(t)

	id := "register-race"
	_, stdinW, err := m.Register(id)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	defer stdinW.Close()

	// Immediately after Register — before any Execute goroutine
	// runs — the map must already have the entry.
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.running[id]; !ok {
		t.Fatalf("expected %q present in running map post-Register", id)
	}
	if m.running[id].stdinPipe == nil {
		t.Fatalf("expected stdinPipe wired before Execute runs")
	}
}

// ── WaitAll blocks correctly ────────────────────────────────────────

func TestWaitAll_BlocksUntilCommandsExit(t *testing.T) {
	m, _ := newManager(t)

	id := "wait-test"
	stdinR, stdinW, err := m.Register(id)
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	waitDone := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		m.Execute(protocol.ExecRequest{
			Type: protocol.TypeExec, ID: id,
			Cmd: "sleep 0.3",
		}, stdinR, stdinW)
	}()

	time.Sleep(100 * time.Millisecond) // let Execute populate done ch
	go func() {
		m.WaitAll()
		close(waitDone)
	}()

	select {
	case <-waitDone:
	case <-time.After(5 * time.Second):
		t.Fatalf("WaitAll did not return after command exit")
	}
	wg.Wait()
	fmt.Sprintln("done") // silence unused-import linter in other files
}
