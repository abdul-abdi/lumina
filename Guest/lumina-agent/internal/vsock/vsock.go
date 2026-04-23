// Package vsock implements a net.Listener / net.Conn over AF_VSOCK
// using raw syscalls. We deliberately avoid pulling in a third-party
// vsock library to keep the guest binary minimal — the surface here
// is small enough to own.
package vsock

import (
	"fmt"
	"net"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// Listen binds a vsock listener on the given port, accepting from any CID.
func Listen(port int) (net.Listener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("vsock socket: %w", err)
	}

	sa := &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: uint32(port)}
	if err := unix.Bind(fd, sa); err != nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("vsock bind port %d: %w", port, err)
	}

	if err := unix.Listen(fd, 1); err != nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("vsock listen port %d: %w", port, err)
	}

	return &listener{fd: fd}, nil
}

// ── listener ────────────────────────────────────────────────────────

type listener struct {
	fd int
}

func (l *listener) Accept() (net.Conn, error) {
	nfd, _, err := unix.Accept(l.fd)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(nfd), "vsock-conn")
	return &conn{file: file}, nil
}

func (l *listener) Close() error { return unix.Close(l.fd) }
func (l *listener) Addr() net.Addr { return addr{} }

// ── conn ────────────────────────────────────────────────────────────

type conn struct {
	file *os.File
}

func (c *conn) Read(b []byte) (int, error)  { return c.file.Read(b) }
func (c *conn) Write(b []byte) (int, error) { return c.file.Write(b) }
func (c *conn) Close() error                { return c.file.Close() }

func (c *conn) LocalAddr() net.Addr                { return addr{} }
func (c *conn) RemoteAddr() net.Addr               { return addr{} }
func (c *conn) SetDeadline(t time.Time) error      { return c.file.SetDeadline(t) }
func (c *conn) SetReadDeadline(t time.Time) error  { return c.file.SetReadDeadline(t) }
func (c *conn) SetWriteDeadline(t time.Time) error { return c.file.SetWriteDeadline(t) }

// ── addr ────────────────────────────────────────────────────────────

type addr struct{}

func (addr) Network() string { return "vsock" }
func (addr) String() string  { return "vsock" }
