// Guest/lumina-agent/main.go
package main

import (
	"bufio"
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

// Protocol messages

type ExecRequest struct {
	Type    string            `json:"type"`
	ID      string            `json:"id"`
	Cmd     string            `json:"cmd"`
	Timeout int               `json:"timeout"`
	Env     map[string]string `json:"env"`
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
	Type   string `json:"type"`
	ID     string `json:"id"`
	Stream string `json:"stream"`
	Data   string `json:"data"`
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

func main() {
	// Log to serial console (stderr goes to serial on most VM setups)
	fmt.Fprintln(os.Stderr, agentStartMsg)

	// Listen on vsock
	ln, err := listenVsock(vsockPort)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to listen on vsock port %d: %v\n", vsockPort, err)
		os.Exit(1)
	}
	defer ln.Close()

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
			// Dispatch to goroutine for concurrent execution
			go executeCommand(conn, req)

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

func executeCommand(conn net.Conn, req ExecRequest) {
	cmd := exec.Command("/bin/sh", "-c", req.Cmd)

	// Create process group so we can kill the entire tree on timeout
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Set environment
	cmd.Env = os.Environ()
	for k, v := range req.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}

	// Create pipes manually instead of using cmd.StdoutPipe()/StderrPipe()/StdinPipe().
	// Go's exec.Cmd.Wait() closes pipes in closeAfterWait BEFORE our streamPipe
	// goroutines finish reading. For fast commands (echo), Wait() can close the
	// read-end fd while buffered data is unread, causing EBADF and silent data loss.
	// By creating pipes ourselves, cmd.Wait() has nothing in closeAfterWait,
	// so we control the pipe lifecycle completely.
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		sendOutput(conn, req.ID, "stderr", fmt.Sprintf("failed to create stdout pipe: %v\n", err))
		sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: 127})
		return
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		stdoutR.Close()
		stdoutW.Close()
		sendOutput(conn, req.ID, "stderr", fmt.Sprintf("failed to create stderr pipe: %v\n", err))
		sendJSON(conn, ExitMsg{Type: "exit", ID: req.ID, Code: 127})
		return
	}
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		stdoutR.Close()
		stdoutW.Close()
		stderrR.Close()
		stderrW.Close()
		sendOutput(conn, req.ID, "stderr", fmt.Sprintf("failed to create stdin pipe: %v\n", err))
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

	// Track this command for stdin/cancel routing
	cmdCtx, cmdCancel := context.WithCancel(context.Background())
	doneCh := make(chan struct{})

	rc := &runningCmd{
		cmd:       cmd,
		stdinPipe: stdinW, // handleStdin writes to the write-end
		cancel:    cmdCancel,
		done:      doneCh,
	}

	cmdMu.Lock()
	runningCmds[req.ID] = rc
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
			sendOutput(conn, id, stream, string(buf[:n]))
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
