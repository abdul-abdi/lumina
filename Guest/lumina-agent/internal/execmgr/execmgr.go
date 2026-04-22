// Package execmgr runs shell commands on behalf of the host. Each
// command runs in its own process group (so SIGTERM/SIGKILL can tear
// down the entire descendant tree) and streams stdout/stderr to the
// host in chunks — text frames for valid UTF-8, base64 frames for
// binary bytes.
package execmgr

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// Manager tracks in-flight commands so stdin/cancel/teardown can find
// them by ID.
type Manager struct {
	w *wire.Writer

	mu      sync.Mutex
	running map[string]*runningCmd
}

// New creates an empty Manager.
func New(w *wire.Writer) *Manager {
	return &Manager{w: w, running: make(map[string]*runningCmd)}
}

// runningCmd tracks a single in-flight command. stdinPipe is seeded
// by Register before the goroutine that will run the command starts,
// so stdin / stdin_close messages arriving immediately after exec
// cannot race the goroutine's registration and get silently dropped.
// See `Register` for the full rationale.
type runningCmd struct {
	cmd       *exec.Cmd
	stdinPipe io.WriteCloser
	cancel    context.CancelFunc
	done      chan struct{}
}

// Register pre-creates a stdin pipe and inserts a map entry BEFORE
// the goroutine that runs the command starts. Without this, stdin
// frames arriving between the host's exec request and the goroutine's
// own registration step would be dropped by Stdin/StdinClose lookups.
// The returned writer is what the goroutine will pass to cmd.Stdin
// (the read end becomes cmd.Stdin after Register returns).
func (m *Manager) Register(id string) (stdinR, stdinW *os.File, err error) {
	stdinR, stdinW, err = os.Pipe()
	if err != nil {
		return nil, nil, err
	}
	m.mu.Lock()
	m.running[id] = &runningCmd{stdinPipe: stdinW}
	m.mu.Unlock()
	return stdinR, stdinW, nil
}

// Unregister removes an entry; used when a command failed to start
// (after Register was called).
func (m *Manager) Unregister(id string) {
	m.mu.Lock()
	delete(m.running, id)
	m.mu.Unlock()
}

// Execute runs req on the caller's goroutine. stdinR/stdinW must come
// from Register — this function takes ownership of them.
func (m *Manager) Execute(req protocol.ExecRequest, stdinR, stdinW *os.File) {
	cmd := exec.Command("/bin/sh", "-c", req.Cmd)
	// Process group so the whole descendant tree can be killed together.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	cmd.Env = os.Environ()
	for k, v := range req.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	}

	// Manual pipe creation: exec.Cmd.Wait() closes StdoutPipe/StderrPipe
	// in closeAfterWait BEFORE streamer goroutines finish reading. For
	// fast commands, Wait() can close the read-end while buffered data
	// is unread, causing EBADF and silent data loss. We own the pipes
	// so cmd.Wait() has nothing in closeAfterWait and we control the
	// lifecycle end to end.
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		m.failStart(req.ID, stdinR, stdinW, nil, nil, nil, nil, err, "stdout pipe")
		return
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		m.failStart(req.ID, stdinR, stdinW, stdoutR, stdoutW, nil, nil, err, "stderr pipe")
		return
	}

	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW
	cmd.Stdin = stdinR

	if err := cmd.Start(); err != nil {
		m.failStart(req.ID, stdinR, stdinW, stdoutR, stdoutW, stderrR, stderrW, err, "start command")
		return
	}

	// Parent closes its copies of the child's stdin-read and
	// stdout/stderr-write ends. The child retains dup'd descriptors.
	_ = stdoutW.Close()
	_ = stderrW.Close()
	_ = stdinR.Close()

	// Upgrade the pre-registered entry with cmd + cancel + done.
	cmdCtx, cmdCancel := context.WithCancel(context.Background())
	doneCh := make(chan struct{})
	m.mu.Lock()
	if rc := m.running[req.ID]; rc != nil {
		rc.cmd = cmd
		rc.cancel = cmdCancel
		rc.done = doneCh
	} else {
		// Defensive — Register should always insert first.
		m.running[req.ID] = &runningCmd{
			cmd: cmd, stdinPipe: stdinW, cancel: cmdCancel, done: doneCh,
		}
	}
	m.mu.Unlock()

	defer func() {
		m.mu.Lock()
		delete(m.running, req.ID)
		m.mu.Unlock()
		cmdCancel()
		_ = stdinW.Close()
		_ = stdoutR.Close()
		_ = stderrR.Close()
		close(doneCh)
	}()

	// Stream output concurrently. Streamers read from our manually-owned
	// read-ends, which are NOT closed by cmd.Wait(); they stay open
	// until the defer above, AFTER wg.Wait() drains them.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); streamPipe(m.w, req.ID, protocol.StreamStdout, stdoutR) }()
	go func() { defer wg.Done(); streamPipe(m.w, req.ID, protocol.StreamStderr, stderrR) }()

	// Exit handling: timeout → SIGTERM → 5s grace → SIGKILL.
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	var cmdErr error
	if req.Timeout > 0 {
		timer := time.NewTimer(time.Duration(req.Timeout) * time.Second)
		defer timer.Stop()
		select {
		case cmdErr = <-waitCh:
		case <-timer.C:
			cmdErr = gracefulKill(cmd, waitCh, 5*time.Second)
		case <-cmdCtx.Done():
			cmdErr = gracefulKill(cmd, waitCh, 5*time.Second)
		}
	} else {
		select {
		case cmdErr = <-waitCh:
		case <-cmdCtx.Done():
			cmdErr = gracefulKill(cmd, waitCh, 5*time.Second)
		}
	}

	wg.Wait()

	exitCode := 0
	if cmdErr != nil {
		if exitErr, ok := cmdErr.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = 1
		}
	}

	_ = m.w.Send(protocol.NewExit(req.ID, exitCode))
}

// Stdin forwards data to a running command's stdin pipe. Silently
// drops if the command has already exited.
func (m *Manager) Stdin(msg protocol.StdinMsg) {
	m.mu.Lock()
	rc := m.running[msg.ID]
	m.mu.Unlock()
	if rc != nil && rc.stdinPipe != nil {
		_, _ = rc.stdinPipe.Write([]byte(msg.Data))
	}
}

// StdinClose closes the stdin pipe for a running command.
func (m *Manager) StdinClose(msg protocol.StdinCloseMsg) {
	m.mu.Lock()
	rc := m.running[msg.ID]
	m.mu.Unlock()
	if rc != nil && rc.stdinPipe != nil {
		_ = rc.stdinPipe.Close()
	}
}

// Cancel sends sig to a specific command (by id) or all running
// commands (if id is empty). If gracePeriod > 0 and sig != SIGKILL,
// a follow-up SIGKILL is scheduled.
func (m *Manager) Cancel(msg protocol.CancelMsg) {
	sig := syscall.Signal(msg.Signal)
	if sig == 0 {
		sig = syscall.SIGTERM
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if msg.ID != "" {
		if rc := m.running[msg.ID]; rc != nil {
			m.killLocked(rc, sig, msg.GracePeriod)
		}
		return
	}
	for _, rc := range m.running {
		m.killLocked(rc, sig, msg.GracePeriod)
	}
}

// KillAll SIGKILLs every running command. Used when the connection to
// the host drops — we want to release resources fast.
func (m *Manager) KillAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, rc := range m.running {
		if rc.cmd != nil && rc.cmd.Process != nil {
			_ = syscall.Kill(-rc.cmd.Process.Pid, syscall.SIGKILL)
		}
	}
}

// WaitAll blocks until every running command's done channel is closed.
func (m *Manager) WaitAll() {
	m.mu.Lock()
	cmds := make([]*runningCmd, 0, len(m.running))
	for _, rc := range m.running {
		cmds = append(cmds, rc)
	}
	m.mu.Unlock()
	for _, rc := range cmds {
		if rc.done != nil {
			<-rc.done
		}
	}
}

// ── private ─────────────────────────────────────────────────────────

// killLocked assumes m.mu is held.
func (m *Manager) killLocked(rc *runningCmd, sig syscall.Signal, gracePeriod int) {
	if rc.cmd == nil || rc.cmd.Process == nil {
		return
	}
	pgid := -rc.cmd.Process.Pid
	_ = syscall.Kill(pgid, sig)

	if sig != syscall.SIGKILL && gracePeriod > 0 {
		go func() {
			time.Sleep(time.Duration(gracePeriod) * time.Second)
			m.mu.Lock()
			defer m.mu.Unlock()
			// Only SIGKILL if this exact struct is still tracked.
			for _, existing := range m.running {
				if existing == rc && rc.cmd.Process != nil {
					_ = syscall.Kill(-rc.cmd.Process.Pid, syscall.SIGKILL)
					return
				}
			}
		}()
	}
}

// failStart reports a start-path failure and releases any fds the
// caller created. The variadic-looking arg list keeps the happy path
// free of branch-on-nil noise.
func (m *Manager) failStart(
	id string,
	stdinR, stdinW, stdoutR, stdoutW, stderrR, stderrW *os.File,
	cause error,
	phase string,
) {
	for _, f := range []*os.File{stdinR, stdinW, stdoutR, stdoutW, stderrR, stderrW} {
		if f != nil {
			_ = f.Close()
		}
	}
	m.Unregister(id)
	_ = m.w.Send(protocol.OutputMsg{
		Type:   protocol.TypeOutput,
		ID:     id,
		Stream: protocol.StreamStderr,
		Data:   fmt.Sprintf("failed to %s: %v\n", phase, cause),
	})
	_ = m.w.Send(protocol.NewExit(id, 127))
}

// gracefulKill sends SIGTERM, waits, then SIGKILL.
func gracefulKill(cmd *exec.Cmd, waitCh <-chan error, grace time.Duration) error {
	if cmd.Process == nil {
		return <-waitCh
	}
	pgid := -cmd.Process.Pid
	_ = syscall.Kill(pgid, syscall.SIGTERM)

	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case err := <-waitCh:
		return err
	case <-timer.C:
		_ = syscall.Kill(pgid, syscall.SIGKILL)
		return <-waitCh
	}
}

// streamPipe reads from pipe, auto-detecting text vs binary per chunk.
func streamPipe(w *wire.Writer, id string, stream string, pipe io.ReadCloser) {
	buf := make([]byte, protocol.MaxChunkSize)
	for {
		n, err := pipe.Read(buf)
		if n > 0 {
			chunk := buf[:n]
			if utf8.Valid(chunk) {
				sendText(w, id, stream, string(chunk))
			} else {
				sendBinary(w, id, stream, chunk)
			}
		}
		if err != nil {
			return
		}
	}
}

// sendText chunks long strings under the frame cap.
func sendText(w *wire.Writer, id string, stream string, data string) {
	for len(data) > 0 {
		cut := len(data)
		if cut > protocol.MaxChunkSize {
			cut = protocol.MaxChunkSize
		}
		_ = w.Send(protocol.OutputMsg{
			Type:   protocol.TypeOutput,
			ID:     id,
			Stream: stream,
			Data:   data[:cut],
		})
		data = data[cut:]
	}
}

// sendBinary base64-encodes and chunks so the encoded payload stays
// under the frame cap. 48 KiB raw → ~64 KiB base64.
func sendBinary(w *wire.Writer, id string, stream string, raw []byte) {
	const rawChunk = (protocol.MaxChunkSize / 4) * 3
	for len(raw) > 0 {
		n := len(raw)
		if n > rawChunk {
			n = rawChunk
		}
		_ = w.Send(protocol.OutputMsg{
			Type:     protocol.TypeOutput,
			ID:       id,
			Stream:   stream,
			Data:     base64.StdEncoding.EncodeToString(raw[:n]),
			Encoding: "base64",
		})
		raw = raw[n:]
	}
}
