// Package ptymgr runs interactive (PTY) commands. One active PTY per
// session is enforced at the session layer on the host; this package
// just tracks in-flight PTYs so input / resize / teardown can find
// them by ID.
package ptymgr

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// drainWindow — after the first byte arrives on the PTY master, we
// continue reading for this long to coalesce bursts into one frame,
// avoiding per-character JSON overhead.
const drainWindow = 5 * time.Millisecond

// readBufSize — per-read chunk; a burst aggregates up to 8 KiB before
// flushing mid-window.
const readBufSize = 4096

// pendingResizeTTL — a window_resize that arrives for a PTY id whose
// pty_exec never lands (client crashed between the two messages, or
// the exec was rejected by the session layer) sits in pendingResizes
// forever. Bounded by unique IDs, but unbounded across agent lifetime
// so a long-running session can leak memory at one small struct per
// orphan. Evicting anything older than this window costs one
// time.Now() per insert, keeps the map size at most "resizes received
// in the last TTL" regardless of how long the agent has run. Chosen
// to be long enough that a slow client placing resize-before-exec is
// still correct.
const pendingResizeTTL = 60 * time.Second

// Manager tracks in-flight PTY sessions.
type Manager struct {
	w *wire.Writer

	mu      sync.Mutex
	running map[string]*runningPty

	pendingMu      sync.Mutex
	pendingResizes map[string]winsize

	// now is the time source; real code uses time.Now, tests inject a
	// fake so pendingResizeTTL is exercisable without sleeping.
	now func() time.Time
}

// New creates an empty Manager.
func New(w *wire.Writer) *Manager {
	return &Manager{
		w:              w,
		running:        make(map[string]*runningPty),
		pendingResizes: make(map[string]winsize),
		now:            time.Now,
	}
}

type runningPty struct {
	masterFd int
	cmd      *exec.Cmd
	cancel   context.CancelFunc
	done     chan struct{}
}

type winsize struct {
	cols, rows int
	// enqueuedAt is the moment Resize buffered this entry. Used by
	// the TTL eviction pass on every insert to keep the pending map
	// bounded across agent lifetime.
	enqueuedAt time.Time
}

// HasActive reports whether a PTY with the given id is running.
func (m *Manager) HasActive(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.running[id]
	return ok
}

// KillAll SIGKILLs every running PTY process group. Paired with
// execmgr.KillAll on heartbeat failure — without this, a disconnected
// host leaves shell processes running until the next accept cycle.
// The Execute goroutine's cmd.Wait unblocks, its defer deletes the map
// entry, and the next connection starts with a clean slate.
func (m *Manager) KillAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, p := range m.running {
		if p.cmd != nil && p.cmd.Process != nil {
			_ = syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL)
		}
		if p.cancel != nil {
			p.cancel()
		}
	}
}

// Input forwards raw bytes to the master fd. Silently drops if the
// PTY has exited.
func (m *Manager) Input(msg protocol.PtyInputMsg) {
	decoded, err := base64.StdEncoding.DecodeString(msg.Data)
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "pty_input base64 decode failed: %v\n", err)
		return
	}
	m.mu.Lock()
	p, ok := m.running[msg.ID]
	m.mu.Unlock()
	if !ok {
		return
	}
	if _, err := unix.Write(p.masterFd, decoded); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "pty master write (id=%s): %v\n", msg.ID, err)
	}
}

// Resize either applies a resize immediately (if the PTY is live) or
// buffers it for Execute to apply when it allocates the master fd.
// Silently drops if the PTY has already exited.
func (m *Manager) Resize(msg protocol.WindowResizeMsg) {
	m.mu.Lock()
	p, ok := m.running[msg.ID]
	m.mu.Unlock()
	if ok {
		ws := unix.Winsize{Row: uint16(msg.Rows), Col: uint16(msg.Cols)}
		if err := unix.IoctlSetWinsize(p.masterFd, unix.TIOCSWINSZ, &ws); err != nil {
			_, _ = fmt.Fprintf(os.Stderr, "pty resize (id=%s): %v\n", msg.ID, err)
		}
		return
	}
	// Buffer for a PTY not yet allocated, and opportunistically sweep
	// any stale entries older than pendingResizeTTL — this keeps the
	// map bounded even if a stream of resize-before-exec messages from
	// crashing clients never gets its matching pty_exec.
	now := m.now()
	m.pendingMu.Lock()
	for id, entry := range m.pendingResizes {
		if now.Sub(entry.enqueuedAt) > pendingResizeTTL {
			delete(m.pendingResizes, id)
		}
	}
	m.pendingResizes[msg.ID] = winsize{
		cols: msg.Cols, rows: msg.Rows, enqueuedAt: now,
	}
	m.pendingMu.Unlock()
}

// Execute runs req under a freshly allocated PTY. It owns the PTY
// master/slave lifecycle and sends exit when the process terminates.
func (m *Manager) Execute(req protocol.PtyExecRequest) {
	id := req.ID

	masterFd, slavePath, err := openPty()
	if err != nil {
		m.sendErrorAndExit(id, fmt.Sprintf("openpty failed: %v", err))
		return
	}
	defer unix.Close(masterFd)

	slaveFd, err := unix.Open(slavePath, unix.O_RDWR, 0)
	if err != nil {
		m.sendErrorAndExit(id, fmt.Sprintf("open slave failed: %v", err))
		return
	}

	// Initial size: from request, unless a pending resize beat us here.
	ws := unix.Winsize{Row: uint16(req.Rows), Col: uint16(req.Cols)}
	m.pendingMu.Lock()
	if pending, ok := m.pendingResizes[id]; ok {
		ws.Col = uint16(pending.cols)
		ws.Row = uint16(pending.rows)
		delete(m.pendingResizes, id)
	}
	m.pendingMu.Unlock()
	if err := unix.IoctlSetWinsize(masterFd, unix.TIOCSWINSZ, &ws); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "pty initial winsize (id=%s): %v\n", id, err)
	}

	// Build child command with slave as tty.
	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", req.Cmd)
	cmd.Env = append(os.Environ(),
		append(envPairs(req.Env),
			"TERM=xterm-256color",
			fmt.Sprintf("COLUMNS=%d", ws.Col),
			fmt.Sprintf("LINES=%d", ws.Row),
		)...,
	)

	slaveFile := os.NewFile(uintptr(slaveFd), slavePath)
	cmd.Stdin = slaveFile
	cmd.Stdout = slaveFile
	cmd.Stderr = slaveFile
	// Ctty=0 because Stdin/Stdout/Stderr all point at slaveFile, so fd 0
	// in the child's table is the controlling terminal.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}

	doneCh := make(chan struct{})
	m.mu.Lock()
	m.running[id] = &runningPty{masterFd: masterFd, cmd: cmd, cancel: cancel, done: doneCh}
	m.mu.Unlock()
	defer func() {
		cancel()
		m.mu.Lock()
		delete(m.running, id)
		m.mu.Unlock()
		close(doneCh)
	}()

	if err := cmd.Start(); err != nil {
		_ = slaveFile.Close()
		m.sendErrorAndExit(id, fmt.Sprintf("start failed: %v", err))
		return
	}
	_ = slaveFile.Close() // child has its own dup'd fd

	// Reader goroutine: chunk + drain-window coalesce.
	readDone := make(chan struct{})
	go m.readMaster(id, masterFd, readDone)

	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = 1
		}
	}
	<-readDone // drain remaining master output before sending exit

	_ = m.w.Send(protocol.NewExit(id, exitCode))
}

// ── private ─────────────────────────────────────────────────────────

func (m *Manager) readMaster(id string, masterFd int, done chan<- struct{}) {
	defer close(done)
	buf := make([]byte, readBufSize)
	for {
		n, err := unix.Read(masterFd, buf)
		if n > 0 {
			accum := make([]byte, 0, 8192)
			accum = append(accum, buf[:n]...)
			// Coalesce a drain window of additional bytes without
			// holding up the master for long.
			deadline := time.Now().Add(drainWindow)
			_ = unix.SetNonblock(masterFd, true)
			for time.Now().Before(deadline) {
				dn, derr := unix.Read(masterFd, buf)
				if dn > 0 {
					accum = append(accum, buf[:dn]...)
				}
				if derr != nil || dn == 0 {
					break
				}
			}
			_ = unix.SetNonblock(masterFd, false)
			_ = m.w.Send(protocol.PtyOutputMsg{
				Type: protocol.TypePtyOutput,
				ID:   id,
				Data: base64.StdEncoding.EncodeToString(accum),
			})
		}
		if err != nil {
			// EIO = slave closed before process exit (normal PTY teardown).
			// Other errors are also terminal (EBADF, etc.).
			if err != unix.EIO {
				_, _ = fmt.Fprintf(os.Stderr, "pty master read error (id=%s): %v\n", id, err)
			}
			return
		}
		if n == 0 {
			return
		}
	}
}

// sendErrorAndExit writes a pty_output text frame then exit 127.
func (m *Manager) sendErrorAndExit(id, text string) {
	_ = m.w.Send(protocol.PtyOutputMsg{
		Type: protocol.TypePtyOutput,
		ID:   id,
		Data: base64.StdEncoding.EncodeToString([]byte(text + "\r\n")),
	})
	_ = m.w.Send(protocol.NewExit(id, 127))
}

// openPty allocates a /dev/ptmx master + slave pair.
func openPty() (masterFd int, slavePath string, err error) {
	masterFd, err = unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		return 0, "", fmt.Errorf("open /dev/ptmx: %w", err)
	}
	// TIOCSPTLCK=0 unlocks the slave before TIOCGPTN returns a usable pts.
	if err := unix.IoctlSetPointerInt(masterFd, unix.TIOCSPTLCK, 0); err != nil {
		_ = unix.Close(masterFd)
		return 0, "", fmt.Errorf("TIOCSPTLCK: %w", err)
	}
	ptsNum, err := unix.IoctlGetInt(masterFd, unix.TIOCGPTN)
	if err != nil {
		_ = unix.Close(masterFd)
		return 0, "", fmt.Errorf("TIOCGPTN: %w", err)
	}
	return masterFd, fmt.Sprintf("/dev/pts/%d", ptsNum), nil
}

// envPairs converts the request env map to "k=v" strings.
func envPairs(env map[string]string) []string {
	pairs := make([]string, 0, len(env))
	for k, v := range env {
		pairs = append(pairs, fmt.Sprintf("%s=%s", k, v))
	}
	return pairs
}
