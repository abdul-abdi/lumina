// Guest/lumina-agent/main.go
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	vsockPort     = 1024
	maxChunkSize  = 65536 // 64KB
	agentStartMsg = "lumina-agent starting"
)

// Protocol messages

type ExecRequest struct {
	Type    string            `json:"type"`
	Cmd     string            `json:"cmd"`
	Timeout int               `json:"timeout"`
	Env     map[string]string `json:"env"`
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

	// Accept one connection
	conn, err := ln.Accept()
	if err != nil {
		fmt.Fprintf(os.Stderr, "accept failed: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	// Send ready message
	sendJSON(conn, ReadyMsg{Type: "ready"})

	// Read exec request
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, maxChunkSize*2), maxChunkSize*2)
	if !scanner.Scan() {
		fmt.Fprintln(os.Stderr, "failed to read exec request")
		os.Exit(1)
	}

	var req ExecRequest
	if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
		fmt.Fprintf(os.Stderr, "invalid exec request: %v\n", err)
		os.Exit(1)
	}

	if req.Type != "exec" {
		fmt.Fprintf(os.Stderr, "unexpected message type: %s\n", req.Type)
		os.Exit(1)
	}

	// Execute command
	exitCode := executeCommand(conn, req)

	// Send exit
	sendJSON(conn, ExitMsg{Type: "exit", Code: exitCode})
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

	// Stream stdout and stderr concurrently
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); streamPipe(conn, "stdout", stdoutPipe) }()
	go func() { defer wg.Done(); streamPipe(conn, "stderr", stderrPipe) }()

	// Timeout handling
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	var cmdErr error
	if req.Timeout > 0 {
		timer := time.NewTimer(time.Duration(req.Timeout) * time.Second)
		defer timer.Stop()
		select {
		case cmdErr = <-done:
		case <-timer.C:
			// Kill the process group
			if cmd.Process != nil {
				syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			}
			cmdErr = <-done
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
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	data = append(data, '\n')
	conn.Write(data)
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
