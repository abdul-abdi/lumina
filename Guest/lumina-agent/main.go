// Guest/lumina-agent/main.go
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

const (
	vsockPort         = 1024
	maxChunkSize      = 65536 // 64KB
	heartbeatInterval = 2 * time.Second
	agentStartMsg     = "lumina-agent starting"
)

// writeMu serializes all writes to the vsock connection.
// Required because heartbeat goroutine and command execution
// goroutines may write concurrently.
var writeMu sync.Mutex

// runningCmd tracks a concurrently executing command.
// stdinPipe is populated synchronously in the main scanner loop (before the
// executeCommand goroutine runs) so that stdin/stdin_close messages arriving
// immediately after exec cannot race the goroutine's registration and get
// silently dropped. The other fields are populated by the goroutine once
// cmd.Start succeeds.
type runningCmd struct {
	cmd       *exec.Cmd
	stdinPipe io.WriteCloser
	cancel    context.CancelFunc
	done      chan struct{}
}

// cmdMu protects runningCmds — the map of currently executing commands.
var (
	cmdMu       sync.Mutex
	runningCmds = make(map[string]*runningCmd)
)

// PTY tracking
type runningPty struct {
	masterFd int
	cmd      *exec.Cmd
	cancel   context.CancelFunc
	done     chan struct{}
}

var (
	ptyMu       sync.Mutex
	runningPtys = make(map[string]*runningPty)

	// Pending window resizes for PTYs not yet allocated
	pendingResizeMu sync.Mutex
	pendingResizes  = make(map[string][2]int) // id -> [cols, rows]
)

// Protocol messages

type ExecRequest struct {
	Type    string            `json:"type"`
	ID      string            `json:"id"`
	Cmd     string            `json:"cmd"`
	Timeout int               `json:"timeout"`
	Env     map[string]string `json:"env"`
	Cwd     string            `json:"cwd,omitempty"`
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

type ReadyMsg struct {
	Type string `json:"type"`
}

type HeartbeatMsg struct {
	Type string `json:"type"`
}

type CancelMsg struct {
	Type        string `json:"type"`
	ID          string `json:"id,omitempty"`
	Signal      int    `json:"signal"`
	GracePeriod int    `json:"grace_period"`
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

type ConfigureNetworkMsg struct {
	Type    string `json:"type"`
	IP      string `json:"ip"`
	Gateway string `json:"gateway"`
	DNS     string `json:"dns"`
}

type NetworkReadyMsg struct {
	Type string `json:"type"`
	IP   string `json:"ip"`
}

// PTY message types
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

type PtyOutputMsg struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Data string `json:"data"`
}

// bootMark writes a boot-profile phase marker to /dev/kmsg (kernel log →
// serial console). The host parses these from the SerialConsole buffer to
// build a BootProfile. Safe to call before vsock is up.
func bootMark(phase string) {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return
	}
	t := string(data)
	if i := bytes.IndexByte([]byte(t), ' '); i > 0 {
		t = t[:i]
	}
	msg := fmt.Sprintf("LUMINA_BOOT phase=%s t=%s\n", phase, t)
	if f, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0); err == nil {
		f.WriteString(msg)
		f.Close()
	}
	// Also to stderr, which VZ routes to serial console on this setup.
	fmt.Fprint(os.Stderr, msg)
}

func main() {
	// Log to serial console (stderr goes to serial on most VM setups)
	fmt.Fprintln(os.Stderr, agentStartMsg)
	bootMark("agent_start")

	// Listen on vsock
	ln, err := listenVsock(vsockPort)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to listen on vsock port %d: %v\n", vsockPort, err)
		os.Exit(1)
	}
	defer ln.Close()
	bootMark("vsock_bound")

	// Accept connections in a loop — if a connection drops (host crash, vsock
	// reset), accept a new one so the session can reconnect without rebooting.
	for {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "accept failed: %v\n", err)
			continue
		}

		serveConnection(conn)
		conn.Close()
		fmt.Fprintln(os.Stderr, "connection closed, waiting for reconnect...")
	}
}

func serveConnection(conn net.Conn) {
	// Send ready message
	sendJSON(conn, ReadyMsg{Type: "ready"})
	bootMark("ready_sent")

	// Start heartbeat — runs continuously, including during command execution
	ctx, cancelHeartbeat := context.WithCancel(context.Background())
	defer cancelHeartbeat()
	go heartbeat(ctx, conn)

	// Command loop — accept multiple exec requests on the same connection.
	// Exec requests are dispatched to goroutines for concurrent execution.
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, maxChunkSize*2), maxChunkSize*2)

	for scanner.Scan() {
		// Parse just the type field to dispatch
		var header struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &header); err != nil {
			fmt.Fprintf(os.Stderr, "invalid request: %v\n", err)
			continue
		}

		switch header.Type {
		case "exec":
			var req ExecRequest
			if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
				fmt.Fprintf(os.Stderr, "invalid exec request: %v\n", err)
				continue
			}
			// Pre-create the stdin pipe and register the runningCmd entry
			// synchronously, before spawning the goroutine. Otherwise stdin
			// and stdin_close messages that arrive immediately after exec
			// would race the goroutine's registration and be silently dropped
			// by handleStdin/handleStdinClose (nil map entry). The pipe
			// buffers up to 64KB so data written before cmd.Start is readable.
			stdinR, stdinW, pipeErr := os.Pipe()
			if pipeErr != nil {
				sendOutput(conn, req.ID, "stderr", fmt.Sprintf("failed to create stdin pipe: %v\n", pipeErr))
				sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: 127})
				continue
			}
			cmdMu.Lock()
			runningCmds[req.ID] = &runningCmd{stdinPipe: stdinW}
			cmdMu.Unlock()
			// Dispatch to goroutine for concurrent execution
			go executeCommand(conn, req, stdinR, stdinW)

		case "stdin":
			var msg StdinMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				fmt.Fprintf(os.Stderr, "invalid stdin message: %v\n", err)
				continue
			}
			handleStdin(msg)

		case "stdin_close":
			var msg StdinCloseMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				fmt.Fprintf(os.Stderr, "invalid stdin_close message: %v\n", err)
				continue
			}
			handleStdinClose(msg)

		case "upload":
			var msg UploadMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				sendJSON(conn, map[string]interface{}{
					"type": "upload_error", "path": "", "error": err.Error(),
				})
				continue
			}
			handleUpload(conn, scanner, msg)

		case "download_req":
			var msg DownloadReqMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				sendJSON(conn, map[string]interface{}{
					"type": "download_error", "path": "", "error": err.Error(),
				})
				continue
			}
			handleDownload(conn, msg)

		case "cancel":
			var msg CancelMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				fmt.Fprintf(os.Stderr, "invalid cancel request: %v\n", err)
				continue
			}
			handleCancel(msg)

		case "configure_network":
			var msg ConfigureNetworkMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				fmt.Fprintf(os.Stderr, "invalid configure_network request: %v\n", err)
				continue
			}
			go handleConfigureNetwork(conn, msg)

		case "pty_exec":
			var req PtyExecRequest
			if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
				fmt.Fprintf(os.Stderr, "invalid pty_exec request: %v\n", err)
				continue
			}
			ptyMu.Lock()
			_, exists := runningPtys[req.ID]
			ptyMu.Unlock()
			if exists {
				encoded := base64.StdEncoding.EncodeToString([]byte("pty session already active for this ID\r\n"))
				sendJSON(conn, PtyOutputMsg{Type: "pty_output", ID: req.ID, Data: encoded})
				sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: 1})
				continue
			}
			go executePtyCommand(conn, req)

		case "pty_input":
			var msg PtyInputMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				fmt.Fprintf(os.Stderr, "invalid pty_input: %v\n", err)
				continue
			}
			decoded, err := base64.StdEncoding.DecodeString(msg.Data)
			if err != nil {
				fmt.Fprintf(os.Stderr, "pty_input base64 decode failed: %v\n", err)
				continue
			}
			ptyMu.Lock()
			pty, ok := runningPtys[msg.ID]
			ptyMu.Unlock()
			if ok {
				unix.Write(pty.masterFd, decoded)
			}
			// If PTY not found (already exited), silently drop

		case "window_resize":
			var msg WindowResizeMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				fmt.Fprintf(os.Stderr, "invalid window_resize: %v\n", err)
				continue
			}
			ptyMu.Lock()
			pty, ok := runningPtys[msg.ID]
			ptyMu.Unlock()
			if ok {
				ws := unix.Winsize{Row: uint16(msg.Rows), Col: uint16(msg.Cols)}
				unix.IoctlSetWinsize(pty.masterFd, unix.TIOCSWINSZ, &ws)
			} else {
				// Buffer resize for PTY not yet allocated
				pendingResizeMu.Lock()
				pendingResizes[msg.ID] = [2]int{msg.Cols, msg.Rows}
				pendingResizeMu.Unlock()
			}

		default:
			fmt.Fprintf(os.Stderr, "unexpected message type: %s\n", header.Type)
		}
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "connection error: %v\n", err)
	}

	// Wait for all running commands to finish before returning to accept loop
	waitForAllCommands()
}

func heartbeat(ctx context.Context, conn net.Conn) {
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := writeJSON(conn, HeartbeatMsg{Type: "heartbeat"}); err != nil {
				// Connection lost — kill all running commands so
				// serveConnection returns and we get back to Accept() quickly.
				cmdMu.Lock()
				for _, rc := range runningCmds {
					if rc.cmd != nil && rc.cmd.Process != nil {
						syscall.Kill(-rc.cmd.Process.Pid, syscall.SIGKILL)
					}
				}
				cmdMu.Unlock()
				return
			}
		}
	}
}

// executeCommand runs the command on the goroutine. stdinR / stdinW are
// pre-created by the main scanner loop; this function takes ownership of them.
// The pre-registered runningCmd entry (from the scanner loop) is augmented
// here with cmd/cancel/done once cmd.Start succeeds.
func executeCommand(conn net.Conn, req ExecRequest, stdinR *os.File, stdinW *os.File) {
	cmd := exec.Command("/bin/sh", "-c", req.Cmd)

	// Create process group so we can kill the entire tree on timeout
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Set environment
	cmd.Env = os.Environ()
	for k, v := range req.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}

	// Set working directory if specified
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	}

	// Create stdout/stderr pipes manually instead of using cmd.StdoutPipe()/StderrPipe().
	// Go's exec.Cmd.Wait() closes pipes in closeAfterWait BEFORE our streamPipe
	// goroutines finish reading. For fast commands (echo), Wait() can close the
	// read-end fd while buffered data is unread, causing EBADF and silent data loss.
	// By creating pipes ourselves, cmd.Wait() has nothing in closeAfterWait,
	// so we control the pipe lifecycle completely.
	//
	// stdin pipe is pre-created by the main scanner loop for race-free stdin
	// forwarding (see the exec case in serveConnection).
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		stdinR.Close()
		stdinW.Close()
		cmdMu.Lock()
		delete(runningCmds, req.ID)
		cmdMu.Unlock()
		sendOutput(conn, req.ID, "stderr", fmt.Sprintf("failed to create stdout pipe: %v\n", err))
		sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: 127})
		return
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		stdoutR.Close()
		stdoutW.Close()
		stdinR.Close()
		stdinW.Close()
		cmdMu.Lock()
		delete(runningCmds, req.ID)
		cmdMu.Unlock()
		sendOutput(conn, req.ID, "stderr", fmt.Sprintf("failed to create stderr pipe: %v\n", err))
		sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: 127})
		return
	}

	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW
	cmd.Stdin = stdinR

	if err := cmd.Start(); err != nil {
		stdoutR.Close()
		stdoutW.Close()
		stderrR.Close()
		stderrW.Close()
		stdinR.Close()
		stdinW.Close()
		cmdMu.Lock()
		delete(runningCmds, req.ID)
		cmdMu.Unlock()
		sendOutput(conn, req.ID, "stderr", fmt.Sprintf("failed to start command: %v\n", err))
		sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: 127})
		return
	}

	// Close the write ends of stdout/stderr on our side — the child has its own
	// copy via dup2. When the child exits, no writers remain, and reads get EOF.
	// Close the read end of stdin — the child has its own copy.
	stdoutW.Close()
	stderrW.Close()
	stdinR.Close()

	// Augment the pre-registered runningCmd entry with cmd/cancel/done.
	// stdinPipe was already set when the scanner loop inserted the entry.
	cmdCtx, cmdCancel := context.WithCancel(context.Background())
	doneCh := make(chan struct{})

	cmdMu.Lock()
	if rc := runningCmds[req.ID]; rc != nil {
		rc.cmd = cmd
		rc.cancel = cmdCancel
		rc.done = doneCh
	} else {
		// Shouldn't happen — scanner loop always pre-registers. Defensive.
		runningCmds[req.ID] = &runningCmd{
			cmd:       cmd,
			stdinPipe: stdinW,
			cancel:    cmdCancel,
			done:      doneCh,
		}
	}
	cmdMu.Unlock()

	defer func() {
		cmdMu.Lock()
		delete(runningCmds, req.ID)
		cmdMu.Unlock()
		cmdCancel()
		stdinW.Close()
		stdoutR.Close()
		stderrR.Close()
		close(doneCh)
	}()

	// Stream stdout and stderr concurrently.
	// These goroutines read from our manually-created read-ends, which are NOT
	// closed by cmd.Wait(). They stay open until we close them in defer above,
	// AFTER wg.Wait() ensures all data has been read.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); streamPipe(conn, req.ID, "stdout", stdoutR) }()
	go func() { defer wg.Done(); streamPipe(conn, req.ID, "stderr", stderrR) }()

	// Timeout handling: SIGTERM first, then SIGKILL after 5s grace period
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	var cmdErr error
	if req.Timeout > 0 {
		timer := time.NewTimer(time.Duration(req.Timeout) * time.Second)
		defer timer.Stop()
		select {
		case cmdErr = <-done:
		case <-timer.C:
			cmdErr = gracefulKill(cmd, done, 5*time.Second)
		case <-cmdCtx.Done():
			// Cancelled via cancel message
			cmdErr = gracefulKill(cmd, done, 5*time.Second)
		}
	} else {
		select {
		case cmdErr = <-done:
		case <-cmdCtx.Done():
			cmdErr = gracefulKill(cmd, done, 5*time.Second)
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

	sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: exitCode})
}

// openPty allocates a PTY master/slave pair via /dev/ptmx.
// Returns the master fd, slave path, or an error.
func openPty() (int, string, error) {
	masterFd, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		return 0, "", fmt.Errorf("open /dev/ptmx: %w", err)
	}

	// Unlock slave first — required before TIOCGPTN returns a usable pts
	unlock := 0
	if err := unix.IoctlSetPointerInt(masterFd, unix.TIOCSPTLCK, unlock); err != nil {
		unix.Close(masterFd)
		return 0, "", fmt.Errorf("TIOCSPTLCK: %w", err)
	}

	// Get slave pts number
	ptsNum, err := unix.IoctlGetInt(masterFd, unix.TIOCGPTN)
	if err != nil {
		unix.Close(masterFd)
		return 0, "", fmt.Errorf("TIOCGPTN: %w", err)
	}
	slavePath := fmt.Sprintf("/dev/pts/%d", ptsNum)

	return masterFd, slavePath, nil
}

// executePtyCommand runs a command under a PTY, streaming master output as
// pty_output messages. Input arrives via pty_input messages, resize via
// window_resize. Exits via a standard exit message.
func executePtyCommand(conn net.Conn, req PtyExecRequest) {
	id := req.ID

	// Open PTY master + slave
	masterFd, slavePath, err := openPty()
	if err != nil {
		encoded := base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("openpty failed: %v\r\n", err)))
		sendJSON(conn, PtyOutputMsg{Type: "pty_output", ID: id, Data: encoded})
		sendJSON(conn, ExitMsg{Type: "exit", ID: id, Code: 127})
		return
	}
	defer unix.Close(masterFd)

	// Open slave
	slaveFd, err := unix.Open(slavePath, unix.O_RDWR, 0)
	if err != nil {
		encoded := base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("open slave failed: %v\r\n", err)))
		sendJSON(conn, PtyOutputMsg{Type: "pty_output", ID: id, Data: encoded})
		sendJSON(conn, ExitMsg{Type: "exit", ID: id, Code: 127})
		return
	}

	// Initial size: from request, unless a pending resize arrived before pty_exec completed
	ws := unix.Winsize{Row: uint16(req.Rows), Col: uint16(req.Cols)}
	pendingResizeMu.Lock()
	if pending, ok := pendingResizes[id]; ok {
		ws.Col = uint16(pending[0])
		ws.Row = uint16(pending[1])
		delete(pendingResizes, id)
	}
	pendingResizeMu.Unlock()
	unix.IoctlSetWinsize(masterFd, unix.TIOCSWINSZ, &ws)

	// Build command
	ctx, cancel := context.WithCancel(context.Background())
	shell := "/bin/sh"
	cmd := exec.CommandContext(ctx, shell, "-c", req.Cmd)

	// Environment
	cmd.Env = os.Environ()
	for k, v := range req.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}
	cmd.Env = append(cmd.Env, "TERM=xterm-256color")
	cmd.Env = append(cmd.Env, fmt.Sprintf("COLUMNS=%d", int(ws.Col)))
	cmd.Env = append(cmd.Env, fmt.Sprintf("LINES=%d", int(ws.Row)))

	// Slave as stdin/stdout/stderr
	slaveFile := os.NewFile(uintptr(slaveFd), slavePath)
	cmd.Stdin = slaveFile
	cmd.Stdout = slaveFile
	cmd.Stderr = slaveFile
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
		// Ctty references the index in the child's fd table after fork.
		// With Stdin/Stdout/Stderr all pointing at slaveFile (fds 0,1,2 in child),
		// Ctty: 0 is the controlling terminal.
		Ctty: 0,
	}

	done := make(chan struct{})
	ptyMu.Lock()
	runningPtys[id] = &runningPty{masterFd: masterFd, cmd: cmd, cancel: cancel, done: done}
	ptyMu.Unlock()
	defer func() {
		cancel()
		ptyMu.Lock()
		delete(runningPtys, id)
		ptyMu.Unlock()
		close(done)
	}()

	if err := cmd.Start(); err != nil {
		slaveFile.Close()
		encoded := base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("start failed: %v\r\n", err)))
		sendJSON(conn, PtyOutputMsg{Type: "pty_output", ID: id, Data: encoded})
		sendJSON(conn, ExitMsg{Type: "exit", ID: id, Code: 127})
		return
	}

	// Close slave in parent — child inherits the fd
	slaveFile.Close()

	// Reader goroutine: 4KB chunks with 5ms drain window
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		buf := make([]byte, 4096)
		for {
			n, err := unix.Read(masterFd, buf)
			if n > 0 {
				// 5ms drain window: coalesce bursts into a single message
				accum := make([]byte, 0, 8192)
				accum = append(accum, buf[:n]...)
				drainDeadline := time.Now().Add(5 * time.Millisecond)
				unix.SetNonblock(masterFd, true)
				for time.Now().Before(drainDeadline) {
					dn, derr := unix.Read(masterFd, buf)
					if dn > 0 {
						accum = append(accum, buf[:dn]...)
					}
					if derr != nil {
						break
					}
					if dn == 0 {
						break
					}
				}
				unix.SetNonblock(masterFd, false)
				encoded := base64.StdEncoding.EncodeToString(accum)
				sendJSON(conn, PtyOutputMsg{Type: "pty_output", ID: id, Data: encoded})
			}
			if err != nil {
				// EIO = slave closed before process exit (normal PTY teardown).
				// Other errors are also terminal (EBADF, etc.).
				if err != unix.EIO {
					fmt.Fprintf(os.Stderr, "pty master read error (id=%s): %v\n", id, err)
				}
				return
			}
			if n == 0 {
				return
			}
		}
	}()

	// Wait for process to exit
	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = 1
		}
	}

	// Wait for reader goroutine to drain remaining output
	<-readDone

	sendJSON(conn, ExitMsg{Type: "exit", ID: id, Code: exitCode})
}

// gracefulKill sends SIGTERM to the process group, waits for the grace period,
// then sends SIGKILL if the process hasn't exited.
func gracefulKill(cmd *exec.Cmd, done <-chan error, grace time.Duration) error {
	if cmd.Process == nil {
		return <-done
	}
	pgid := -cmd.Process.Pid
	syscall.Kill(pgid, syscall.SIGTERM)

	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case err := <-done:
		return err
	case <-timer.C:
		syscall.Kill(pgid, syscall.SIGKILL)
		return <-done
	}
}

// handleStdin forwards data to a running command's stdin pipe.
func handleStdin(msg StdinMsg) {
	cmdMu.Lock()
	rc := runningCmds[msg.ID]
	cmdMu.Unlock()

	if rc != nil && rc.stdinPipe != nil {
		rc.stdinPipe.Write([]byte(msg.Data))
	}
}

// handleStdinClose closes the stdin pipe for a running command.
func handleStdinClose(msg StdinCloseMsg) {
	cmdMu.Lock()
	rc := runningCmds[msg.ID]
	cmdMu.Unlock()

	if rc != nil && rc.stdinPipe != nil {
		rc.stdinPipe.Close()
	}
}

// handleCancel sends a signal to a specific command (by ID) or all commands.
func handleCancel(msg CancelMsg) {
	sig := syscall.Signal(msg.Signal)
	if sig == 0 {
		sig = syscall.SIGTERM
	}

	cmdMu.Lock()
	if msg.ID != "" {
		// Cancel specific command
		if rc := runningCmds[msg.ID]; rc != nil {
			killCmd(rc, sig, msg.GracePeriod)
		}
	} else {
		// Cancel all running commands
		for _, rc := range runningCmds {
			killCmd(rc, sig, msg.GracePeriod)
		}
	}
	cmdMu.Unlock()
}

// killCmd sends a signal to a command's process group.
// Must be called with cmdMu held.
func killCmd(rc *runningCmd, sig syscall.Signal, gracePeriod int) {
	if rc.cmd == nil || rc.cmd.Process == nil {
		return
	}
	pgid := -rc.cmd.Process.Pid
	syscall.Kill(pgid, sig)

	if sig != syscall.SIGKILL && gracePeriod > 0 {
		go func() {
			time.Sleep(time.Duration(gracePeriod) * time.Second)
			cmdMu.Lock()
			// Check if the command is still running
			for _, existing := range runningCmds {
				if existing == rc && rc.cmd.Process != nil {
					syscall.Kill(-rc.cmd.Process.Pid, syscall.SIGKILL)
					break
				}
			}
			cmdMu.Unlock()
		}()
	}
}

// waitForAllCommands blocks until all running commands have finished.
func waitForAllCommands() {
	cmdMu.Lock()
	cmds := make([]*runningCmd, 0, len(runningCmds))
	for _, rc := range runningCmds {
		cmds = append(cmds, rc)
	}
	cmdMu.Unlock()

	for _, rc := range cmds {
		<-rc.done
	}
}

// handleConfigureNetwork applies host-driven network configuration, then polls
// for carrier and sends network_ready once traffic can flow.
func handleConfigureNetwork(conn net.Conn, msg ConfigureNetworkMsg) {
	fmt.Fprintf(os.Stderr, "configuring network: ip=%s gw=%s dns=%s\n", msg.IP, msg.Gateway, msg.DNS)

	// Bring interface up
	run("ip", "link", "set", "eth0", "up")

	// Disable IPv6 — VZ NAT only provides IPv4
	os.WriteFile("/proc/sys/net/ipv6/conf/all/disable_ipv6", []byte("1"), 0644)

	// Apply static IP and replace default route (replace beats init-script race)
	run("ip", "addr", "add", msg.IP, "dev", "eth0")
	run("ip", "route", "replace", "default", "via", msg.Gateway)

	// Write DNS
	os.MkdirAll("/etc", 0755)
	os.WriteFile("/etc/resolv.conf", []byte("nameserver "+msg.DNS+"\n"), 0644)

	// Extract bare IP (strip /24 suffix) for the ready message
	bareIP := msg.IP
	if idx := len(bareIP) - 1; idx > 0 {
		for i, c := range bareIP {
			if c == '/' {
				bareIP = bareIP[:i]
				break
			}
		}
	}

	// Poll for operstate "up" via sysfs — no subprocess overhead.
	// VZ NAT interfaces report operstate=up once the link is usable,
	// even if carrier detection is slow. Fall back to carrier check.
	for i := 0; i < 200; i++ { // 200 * 10ms = 2s max
		operstate, err := os.ReadFile("/sys/class/net/eth0/operstate")
		if err == nil {
			state := string(bytes.TrimSpace(operstate))
			if state == "up" || state == "unknown" {
				fmt.Fprintf(os.Stderr, "network operstate=%s after %dms\n", state, i*10)
				sendJSON(conn, NetworkReadyMsg{Type: "network_ready", IP: bareIP})
				return
			}
		}
		// Also check carrier directly via sysfs (no subprocess)
		carrier, cerr := os.ReadFile("/sys/class/net/eth0/carrier")
		if cerr == nil && bytes.TrimSpace(carrier)[0] == '1' {
			fmt.Fprintf(os.Stderr, "network carrier up after %dms\n", i*10)
			sendJSON(conn, NetworkReadyMsg{Type: "network_ready", IP: bareIP})
			return
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Timeout — send ready anyway, config is applied and network likely works
	fmt.Fprintln(os.Stderr, "network readiness timeout, sending network_ready anyway")
	sendJSON(conn, NetworkReadyMsg{Type: "network_ready", IP: bareIP})
}

// run executes a command silently, logging errors to stderr.
func run(name string, args ...string) {
	if err := exec.Command(name, args...).Run(); err != nil {
		fmt.Fprintf(os.Stderr, "%s %v: %v\n", name, args, err)
	}
}

func handleUpload(conn net.Conn, scanner *bufio.Scanner, first UploadMsg) {
	// Ensure parent directory exists
	dir := filepath.Dir(first.Path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		sendJSON(conn, map[string]interface{}{
			"type": "upload_error", "path": first.Path, "error": err.Error(),
		})
		return
	}

	// Create/truncate the file
	f, err := os.Create(first.Path)
	if err != nil {
		sendJSON(conn, map[string]interface{}{
			"type": "upload_error", "path": first.Path, "error": err.Error(),
		})
		return
	}
	defer f.Close()

	// Write first chunk
	chunk, err := base64.StdEncoding.DecodeString(first.Data)
	if err != nil {
		sendJSON(conn, map[string]interface{}{
			"type": "upload_error", "path": first.Path, "error": "base64 decode: " + err.Error(),
		})
		return
	}
	if _, err := f.Write(chunk); err != nil {
		sendJSON(conn, map[string]interface{}{
			"type": "upload_error", "path": first.Path, "error": err.Error(),
		})
		return
	}
	sendJSON(conn, map[string]interface{}{"type": "upload_ack", "seq": first.Seq})

	// Read remaining chunks if not EOF
	if !first.Eof {
		for scanner.Scan() {
			var msg UploadMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				sendJSON(conn, map[string]interface{}{
					"type": "upload_error", "path": first.Path, "error": err.Error(),
				})
				return
			}
			// Skip heartbeat-like messages during upload
			if msg.Type != "upload" {
				continue
			}

			chunk, err := base64.StdEncoding.DecodeString(msg.Data)
			if err != nil {
				sendJSON(conn, map[string]interface{}{
					"type": "upload_error", "path": first.Path, "error": "base64 decode: " + err.Error(),
				})
				return
			}
			if _, err := f.Write(chunk); err != nil {
				sendJSON(conn, map[string]interface{}{
					"type": "upload_error", "path": first.Path, "error": err.Error(),
				})
				return
			}
			sendJSON(conn, map[string]interface{}{"type": "upload_ack", "seq": msg.Seq})

			if msg.Eof {
				break
			}
		}
	}

	// Set file permissions
	if first.Mode != "" {
		mode, err := strconv.ParseUint(first.Mode, 8, 32)
		if err == nil {
			os.Chmod(first.Path, os.FileMode(mode))
		}
	}

	sendJSON(conn, map[string]interface{}{"type": "upload_done", "path": first.Path})
}

func handleDownload(conn net.Conn, req DownloadReqMsg) {
	f, err := os.Open(req.Path)
	if err != nil {
		sendJSON(conn, map[string]interface{}{
			"type": "download_error", "path": req.Path, "error": err.Error(),
		})
		return
	}
	defer f.Close()

	const chunkSize = 45 * 1024
	buf := make([]byte, chunkSize)
	seq := 0
	sentEof := false
	for {
		n, readErr := f.Read(buf)
		if n > 0 {
			b64 := base64.StdEncoding.EncodeToString(buf[:n])
			eof := readErr == io.EOF
			sendJSON(conn, map[string]interface{}{
				"type": "download_data", "path": req.Path, "data": b64, "seq": seq, "eof": eof,
			})
			seq++
			if eof {
				sentEof = true
			}
		}
		if readErr != nil {
			if readErr == io.EOF {
				if !sentEof {
					sendJSON(conn, map[string]interface{}{
						"type": "download_data", "path": req.Path, "data": "", "seq": seq, "eof": true,
					})
				}
				return
			}
			sendJSON(conn, map[string]interface{}{
				"type": "download_error", "path": req.Path, "error": readErr.Error(),
			})
			return
		}
	}
}

func streamPipe(conn net.Conn, id string, stream string, pipe io.ReadCloser) {
	buf := make([]byte, maxChunkSize)
	for {
		n, err := pipe.Read(buf)
		if n > 0 {
			chunk := buf[:n]
			if isValidUTF8(chunk) {
				sendOutput(conn, id, stream, string(chunk))
			} else {
				sendOutputBinary(conn, id, stream, chunk)
			}
		}
		if err != nil {
			break
		}
	}
}

func sendOutput(conn net.Conn, id string, stream string, data string) {
	// Chunk if data exceeds maxChunkSize
	for len(data) > 0 {
		chunk := data
		if len(chunk) > maxChunkSize {
			chunk = data[:maxChunkSize]
		}
		data = data[len(chunk):]
		sendJSON(conn, OutputMsg{Type: "output", ID: id, Stream: stream, Data: chunk})
	}
}

// sendOutputBinary sends raw bytes as a base64-encoded output message.
// Used when a chunk fails UTF-8 validation so the host receives byte-exact data.
func sendOutputBinary(conn net.Conn, id string, stream string, raw []byte) {
	// Chunk to stay under maxChunkSize (base64 expands ~4/3, so chunk at 48KB raw → 64KB base64)
	const rawChunk = (maxChunkSize / 4) * 3 // 48KB
	for len(raw) > 0 {
		n := len(raw)
		if n > rawChunk {
			n = rawChunk
		}
		encoded := base64.StdEncoding.EncodeToString(raw[:n])
		raw = raw[n:]
		sendJSON(conn, OutputMsg{Type: "output", ID: id, Stream: stream, Data: encoded, Encoding: "base64"})
	}
}

// isValidUTF8 reports whether b is valid UTF-8.
func isValidUTF8(b []byte) bool {
	return utf8.Valid(b)
}

func sendJSON(conn net.Conn, v interface{}) {
	writeJSON(conn, v)
}

// writeJSON serializes v as NDJSON and writes to conn. Returns the write error
// (nil on success). Used by heartbeat to detect connection loss.
func writeJSON(conn net.Conn, v interface{}) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	writeMu.Lock()
	_, err = conn.Write(data)
	writeMu.Unlock()
	return err
}

// vsockListener implements net.Listener using raw syscalls.
type vsockListener struct {
	fd int
}

func listenVsock(port int) (net.Listener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}

	sa := &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: uint32(port)}
	if err := unix.Bind(fd, sa); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("bind: %w", err)
	}

	if err := unix.Listen(fd, 1); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("listen: %w", err)
	}

	return &vsockListener{fd: fd}, nil
}

func (l *vsockListener) Accept() (net.Conn, error) {
	nfd, _, err := unix.Accept(l.fd)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(nfd), "vsock-conn")
	conn := &vsockConn{file: file}
	return conn, nil
}

func (l *vsockListener) Close() error {
	return unix.Close(l.fd)
}

func (l *vsockListener) Addr() net.Addr {
	return vsockAddr{}
}

// vsockConn wraps an os.File as a net.Conn for vsock connections.
type vsockConn struct {
	file *os.File
}

func (c *vsockConn) Read(b []byte) (int, error)  { return c.file.Read(b) }
func (c *vsockConn) Write(b []byte) (int, error) { return c.file.Write(b) }
func (c *vsockConn) Close() error                { return c.file.Close() }

func (c *vsockConn) LocalAddr() net.Addr                { return vsockAddr{} }
func (c *vsockConn) RemoteAddr() net.Addr               { return vsockAddr{} }
func (c *vsockConn) SetDeadline(t time.Time) error      { return c.file.SetDeadline(t) }
func (c *vsockConn) SetReadDeadline(t time.Time) error  { return c.file.SetReadDeadline(t) }
func (c *vsockConn) SetWriteDeadline(t time.Time) error { return c.file.SetWriteDeadline(t) }

type vsockAddr struct{}

func (vsockAddr) Network() string { return "vsock" }
func (vsockAddr) String() string  { return "vsock" }
