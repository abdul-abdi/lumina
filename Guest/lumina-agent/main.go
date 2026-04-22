// Guest/lumina-agent/main.go
//
// Linux guest agent: accepts a vsock connection from the host and
// dispatches exec / pty / transfer / network / port-forward requests
// via the packages under ./internal. Everything interesting lives in
// those packages; this file is only process setup and the accept loop.
package main

import (
	"fmt"
	"os"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/agent"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/bootmark"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/vsock"
)

// vsockPort is the fixed port the host dials to reach us. Pinned so
// the host never has to discover it.
const vsockPort = 1024

func main() {
	// stderr → serial console on most VZ setups.
	_, _ = fmt.Fprintln(os.Stderr, "lumina-agent starting")
	bootmark.Mark("agent_start")

	ln, err := vsock.Listen(vsockPort)
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "failed to listen on vsock port %d: %v\n", vsockPort, err)
		os.Exit(1)
	}
	defer ln.Close()
	bootmark.Mark("vsock_bound")

	// One agent per connection. If the host drops (crash, reset), we
	// accept the next connection rather than rebooting the whole VM —
	// session reconnect stays cheap.
	for {
		conn, err := ln.Accept()
		if err != nil {
			_, _ = fmt.Fprintf(os.Stderr, "accept failed: %v\n", err)
			continue
		}
		agent.New(conn).Serve()
		_ = conn.Close()
		_, _ = fmt.Fprintln(os.Stderr, "connection closed, waiting for reconnect...")
	}
}
