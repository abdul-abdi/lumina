// Package network applies host-driven network configuration, then
// polls for carrier and sends network_ready once traffic can flow.
package network

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// maxCarrierWait is the upper bound on how long we poll /sys/class/net
// before sending network_ready regardless. The host treats this as
// best-effort — if we send ready too early, the first packet retries.
const maxCarrierWait = 2 * time.Second

// carrierPollInterval is the sysfs read cadence.
const carrierPollInterval = 10 * time.Millisecond

// Configure applies msg to eth0 (IP/route/DNS), then blocks until the
// interface reports operstate=up or carrier=1, then sends
// NetworkReadyMsg to the host. Returns immediately to the caller; the
// wait is synchronous within this function.
func Configure(w *wire.Writer, msg protocol.ConfigureNetworkMsg) {
	_, _ = fmt.Fprintf(os.Stderr, "configuring network: ip=%s gw=%s dns=%s\n", msg.IP, msg.Gateway, msg.DNS)

	// Bring interface up.
	runSilently("ip", "link", "set", "eth0", "up")

	// VZ NAT is IPv4-only; disable IPv6 so the guest doesn't waste time
	// discovering a missing router.
	_ = os.WriteFile("/proc/sys/net/ipv6/conf/all/disable_ipv6", []byte("1"), 0o644)

	// Apply static IP and replace default route — `replace` beats any
	// init-script race that may have installed an alternate default.
	runSilently("ip", "addr", "add", msg.IP, "dev", "eth0")
	runSilently("ip", "route", "replace", "default", "via", msg.Gateway)

	// DNS. MkdirAll is redundant on Alpine but safe.
	_ = os.MkdirAll("/etc", 0o755)
	_ = os.WriteFile("/etc/resolv.conf", []byte("nameserver "+msg.DNS+"\n"), 0o644)

	bareIP, _, _ := strings.Cut(msg.IP, "/")

	// Poll sysfs for carrier — no subprocess overhead. VZ NAT reports
	// operstate=up once the link is usable; fall back to carrier=1 for
	// drivers that don't transition cleanly.
	deadline := time.Now().Add(maxCarrierWait)
	for time.Now().Before(deadline) {
		if operstateReady() {
			_, _ = fmt.Fprintf(os.Stderr, "network operstate up after %s\n", time.Since(deadline.Add(-maxCarrierWait)))
			_ = w.Send(protocol.NetworkReadyMsg{Type: protocol.TypeNetworkReady, IP: bareIP})
			return
		}
		if carrierUp() {
			_, _ = fmt.Fprintf(os.Stderr, "network carrier up after %s\n", time.Since(deadline.Add(-maxCarrierWait)))
			_ = w.Send(protocol.NetworkReadyMsg{Type: protocol.TypeNetworkReady, IP: bareIP})
			return
		}
		time.Sleep(carrierPollInterval)
	}

	// Timeout — config is applied, interface should work. Surface the
	// timeout on stderr so a host-side log grep can flag slow boots.
	_, _ = fmt.Fprintln(os.Stderr, "network readiness timeout, sending network_ready anyway")
	_ = w.Send(protocol.NetworkReadyMsg{Type: protocol.TypeNetworkReady, IP: bareIP})
}

func operstateReady() bool {
	data, err := os.ReadFile("/sys/class/net/eth0/operstate")
	if err != nil {
		return false
	}
	state := string(bytes.TrimSpace(data))
	return state == "up" || state == "unknown"
}

func carrierUp() bool {
	data, err := os.ReadFile("/sys/class/net/eth0/carrier")
	if err != nil {
		return false
	}
	trimmed := bytes.TrimSpace(data)
	return len(trimmed) > 0 && trimmed[0] == '1'
}

// runSilently exec's a command and logs any failure to stderr.
func runSilently(name string, args ...string) {
	if err := exec.Command(name, args...).Run(); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "%s %v: %v\n", name, args, err)
	}
}
