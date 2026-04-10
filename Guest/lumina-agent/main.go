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

// cmdMu protects currentCmd — the currently executing command.
// Used by the cancel handler to send signals to the active process group.
var (
	cmdMu      sync.Mutex
	currentCmd *exec.Cmd
)

// Protocol messages

type ExecRequest struct {
	Type    string            `json:"type"`
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
	Stream string `json:"stream"`
	Data   string `json:"data"`
}

type ExitMsg struct {
	Type string `json:"type"`
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
	Signal      int    `json:"signal"`
	GracePeriod int    `json:"grace_period"`
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

	// Start heartbeat — runs continuously, including during command execution,
	// so the host can check its deadline between heartbeats.
	ctx, cancelHeartbeat := context.WithCancel(context.Background())
	defer cancelHeartbeat()
	go heartbeat(ctx, conn)

	// Command loop — accept multiple exec requests on the same connection
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
			exitCode := executeCommand(conn, req)
			sendJSON(conn, ExitMsg{Type: "exit", Code: exitCode})

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
				// Connection lost — kill the running command so
				// serveConnection returns and we get back to Accept() quickly.
				// Without this, the guest blocks until its own timeout expires.
				cmdMu.Lock()
				cmd := currentCmd
				cmdMu.Unlock()
				if cmd != nil && cmd.Process != nil {
					syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				}
				return
			}
		}
	}
}

func executeCommand(conn net.Conn, req ExecRequest) int {
	cmd := exec.Command("/bin/sh", "-c", req.Cmd)

	// Create process group so we can kill the entire tree on timeout
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Set environment
	cmd.Env = os.Environ()
	for k, v := range req.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}

	stdoutPipe, _ := cmd.StdoutPipe()
	stderrPipe, _ := cmd.StderrPipe()

	if err := cmd.Start(); err != nil {
		sendOutput(conn, "stderr", fmt.Sprintf("failed to start command: %v\n", err))
		return 127
	}

	// Track current command so the cancel handler can signal it
	cmdMu.Lock()
	currentCmd = cmd
	cmdMu.Unlock()
	defer func() {
		cmdMu.Lock()
		currentCmd = nil
		cmdMu.Unlock()
	}()

	// Stream stdout and stderr concurrently
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); streamPipe(conn, "stdout", stdoutPipe) }()
	go func() { defer wg.Done(); streamPipe(conn, "stderr", stderrPipe) }()

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
		}
	} else {
		cmdErr = <-done
	}

	wg.Wait()

	if cmdErr != nil {
		if exitErr, ok := cmdErr.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}
	return 0
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

// handleCancel sends a signal to the currently executing command's process group.
// If the process doesn't exit within the grace period, it sends SIGKILL.
func handleCancel(msg CancelMsg) {
	cmdMu.Lock()
	cmd := currentCmd
	cmdMu.Unlock()

	if cmd == nil || cmd.Process == nil {
		return
	}

	sig := syscall.Signal(msg.Signal)
	if sig == 0 {
		sig = syscall.SIGTERM
	}
	pgid := -cmd.Process.Pid

	syscall.Kill(pgid, sig)

	// If the requested signal isn't SIGKILL, schedule a SIGKILL after grace period
	if sig != syscall.SIGKILL && msg.GracePeriod > 0 {
		go func() {
			time.Sleep(time.Duration(msg.GracePeriod) * time.Second)
			cmdMu.Lock()
			stillRunning := currentCmd == cmd
			cmdMu.Unlock()
			if stillRunning && cmd.Process != nil {
				syscall.Kill(pgid, syscall.SIGKILL)
			}
		}()
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

	// Stream in 48KB raw chunks (~64KB base64) — never load entire file into memory.
	// Go's Read can return (n>0, io.EOF) on the last read, or (n>0, nil) followed
	// by (0, io.EOF). Handle both: set eof when readErr==io.EOF, and if we reach
	// a zero-byte EOF without having sent eof yet, send a final empty chunk.
	const chunkSize = 45 * 1024 // 45KB raw → ~60KB base64 + JSON envelope < 64KB limit
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
					// Either empty file or exact multiple of chunkSize —
					// send final chunk so the host sees eof: true
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

func streamPipe(conn net.Conn, stream string, pipe io.ReadCloser) {
	buf := make([]byte, maxChunkSize)
	for {
		n, err := pipe.Read(buf)
		if n > 0 {
			sendOutput(conn, stream, string(buf[:n]))
		}
		if err != nil {
			break
		}
	}
}

func sendOutput(conn net.Conn, stream string, data string) {
	// Chunk if data exceeds maxChunkSize
	for len(data) > 0 {
		chunk := data
		if len(chunk) > maxChunkSize {
			chunk = data[:maxChunkSize]
		}
		data = data[len(chunk):]
		sendJSON(conn, OutputMsg{Type: "output", Stream: stream, Data: chunk})
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
// Go's net.FileListener doesn't understand AF_VSOCK, so we
// handle accept/close manually and wrap accepted fds as net.Conn.
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
func (c *vsockConn) RemoteAddr() net.Addr                { return vsockAddr{} }
func (c *vsockConn) SetDeadline(t time.Time) error      { return c.file.SetDeadline(t) }
func (c *vsockConn) SetReadDeadline(t time.Time) error  { return c.file.SetReadDeadline(t) }
func (c *vsockConn) SetWriteDeadline(t time.Time) error { return c.file.SetWriteDeadline(t) }

type vsockAddr struct{}

func (vsockAddr) Network() string { return "vsock" }
func (vsockAddr) String() string  { return "vsock" }
