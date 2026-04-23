// Package network applies host-driven network configuration, then
// verifies the route table and polls for carrier before sending
// network_ready to the host. v0.7.2 reliability pass: individual
// ip-command retries, post-setup route verification, explicit
// error reporting on failure.
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
// for link-up. v0.7.2 perf: dropped from 2s → 400ms after profiling
// showed VZ NAT brings eth0 up in 40–80ms (P95 ~120ms) on M3 hosts.
// The 400ms ceiling covers the worst case observed; if it times out,
// we emit network_ready with Stage="timeout-anyway" so the host can
// treat it as a softer signal.
const maxCarrierWait = 400 * time.Millisecond

// carrierPollInterval is the sysfs read cadence. 5ms gives us an
// 8-16 poll ticks on the typical 50-80ms carrier-up latency, without
// measurably costing anything (open(2)+read(2)+close(2) = ~5µs).
const carrierPollInterval = 5 * time.Millisecond

// ipRetryAttempts is how many times we retry a single `ip` command
// if it fails. Individual retries make the setup robust against
// transient EBUSY from the kernel during concurrent netlink ops.
const ipRetryAttempts = 3

// ipRetryBackoff is the linear backoff between ip retries.
const ipRetryBackoff = 20 * time.Millisecond

// Configure applies msg to eth0 (IP/route/DNS) with retries, verifies
// the routing table reflects the requested default route, then polls
// for carrier and sends NetworkReadyMsg. On hard failure (setup
// couldn't complete even with retries), sends NetworkErrorMsg and
// returns — the host-side caller sees a typed error, not a silent
// best-effort success.
func Configure(w *wire.Writer, msg protocol.ConfigureNetworkMsg) {
	started := time.Now()
	_, _ = fmt.Fprintf(os.Stderr, "configuring network: ip=%s gw=%s dns=%s\n", msg.IP, msg.Gateway, msg.DNS)

	// VZ NAT is IPv4-only; disable IPv6 so the guest doesn't waste
	// time discovering a missing router. Cheap — a single writev.
	_ = os.WriteFile("/proc/sys/net/ipv6/conf/all/disable_ipv6", []byte("1"), 0o644)

	bareIP, _, _ := strings.Cut(msg.IP, "/")

	// Step 1: apply link-up + addr + route. Try once as a batch
	// (fastest), fall back to individual retries if the batch fails
	// or if post-verification shows the route didn't land.
	attempts := 0
	var lastErr error
	batchOK := runIPBatch(msg.IP, msg.Gateway)
	if !batchOK {
		attempts++
	}
	// Post-verification: the batch nominally succeeded, but verify
	// the routing table actually reflects our gateway. On some
	// kernels under load, `route replace` can return 0 without
	// committing if netlink is busy with a concurrent op.
	for !routeVerified(msg.Gateway) && attempts < ipRetryAttempts {
		attempts++
		time.Sleep(ipRetryBackoff * time.Duration(attempts))
		// Retry individually — if only the route is missing, just
		// replace the route; don't redo the link+addr since those
		// are idempotent but add noise.
		if err := runIP("link", "set", "eth0", "up"); err != nil {
			lastErr = fmt.Errorf("link up: %w", err)
		}
		_ = runIP("addr", "add", msg.IP, "dev", "eth0") // benign if already set
		if err := runIP("route", "replace", "default", "via", msg.Gateway); err != nil {
			lastErr = fmt.Errorf("route replace: %w", err)
		}
	}

	if !routeVerified(msg.Gateway) {
		// Hard failure. The route isn't in the table; DNS + outbound
		// traffic won't work. Surface to the host as a typed error
		// so the caller can fail loud instead of silently waiting
		// for packets that will never leave.
		reason := "default route not installed after retries"
		if lastErr != nil {
			reason = lastErr.Error()
		}
		_, _ = fmt.Fprintf(os.Stderr, "network setup failed after %d attempts: %s\n", attempts, reason)
		_ = w.Send(protocol.NetworkErrorMsg{
			Type:     protocol.TypeNetworkError,
			Reason:   reason,
			Attempts: attempts,
		})
		return
	}

	// Step 2: DNS. Best-effort write — if /etc/resolv.conf fails to
	// write, DNS lookups will still work via the host's /etc/hosts
	// overlay or the gateway's DNS proxy if one exists.
	_ = os.MkdirAll("/etc", 0o755)
	if err := os.WriteFile("/etc/resolv.conf", []byte("nameserver "+msg.DNS+"\n"), 0o644); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "resolv.conf write: %v (continuing; network is usable without DNS)\n", err)
	}

	// Step 3: poll for carrier. The route is up; this is the final
	// "link is actually carrying" check before we tell the host
	// packets can flow.
	deadline := started.Add(maxCarrierWait)
	for time.Now().Before(deadline) {
		if operstateReady() {
			elapsed := time.Since(started)
			_, _ = fmt.Fprintf(os.Stderr, "network operstate up after %s\n", elapsed)
			_ = w.Send(protocol.NetworkReadyMsg{
				Type:     protocol.TypeNetworkReady,
				IP:       bareIP,
				ConfigMs: int(elapsed / time.Millisecond),
				Stage:    "operstate",
			})
			return
		}
		if carrierUp() {
			elapsed := time.Since(started)
			_, _ = fmt.Fprintf(os.Stderr, "network carrier up after %s\n", elapsed)
			_ = w.Send(protocol.NetworkReadyMsg{
				Type:     protocol.TypeNetworkReady,
				IP:       bareIP,
				ConfigMs: int(elapsed / time.Millisecond),
				Stage:    "carrier",
			})
			return
		}
		time.Sleep(carrierPollInterval)
	}

	// Timeout on carrier, but the route IS installed (verified
	// above). The interface is likely usable; Linux's TCP/UDP
	// stacks retry on send-failure, so first-packet latency absorbs
	// any remaining lag. Emit network_ready with Stage="timeout-
	// anyway" so the host can surface a soft warning if desired.
	elapsed := time.Since(started)
	_, _ = fmt.Fprintf(os.Stderr, "network readiness timeout after %s; route verified, shipping network_ready (stage=timeout-anyway)\n", elapsed)
	_ = w.Send(protocol.NetworkReadyMsg{
		Type:     protocol.TypeNetworkReady,
		IP:       bareIP,
		ConfigMs: int(elapsed / time.Millisecond),
		Stage:    "timeout-anyway",
	})
}

// runIPBatch runs link-set / addr-add / route-replace as a single
// `ip -batch -` process. Returns true if the batch exited 0.
func runIPBatch(ip, gateway string) bool {
	batch := strings.NewReader(
		"link set eth0 up\n" +
			"addr add " + ip + " dev eth0\n" +
			"route replace default via " + gateway + "\n",
	)
	cmd := exec.Command("ip", "-batch", "-")
	cmd.Stdin = batch
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "ip -batch: %v; stderr=%s\n", err, errBuf.String())
		return false
	}
	return true
}

// runIP runs a single `ip` command and returns any error along with
// stderr context for diagnostics.
func runIP(args ...string) error {
	cmd := exec.Command("ip", args...)
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ip %s: %w (stderr=%q)",
			strings.Join(args, " "), err, errBuf.String())
	}
	return nil
}

// routeVerified checks that the default route in the kernel's
// routing table points to `gateway`. Reads /proc/net/route rather
// than spawning `ip route` for a ~3× speedup (no fork/exec).
//
// The file format is:
//   Iface  Destination  Gateway   Flags  RefCnt  Use  Metric  Mask  MTU  Window  IRTT
//   eth0   00000000     0140A8C0  0003   0       0    0       00000000  0    0       0
// Destination=00000000 is the default (0.0.0.0) route; Gateway is
// little-endian hex (0140A8C0 → 192.168.64.1).
func routeVerified(gateway string) bool {
	data, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return false
	}
	wantHex := ipv4ToLittleEndianHex(gateway)
	if wantHex == "" {
		return false
	}
	scanner := bytes.NewReader(data)
	// Hand-roll the scan — /proc/net/route is small (<1KB) and
	// bufio.Scanner would need an allocation per call.
	buf := make([]byte, scanner.Len())
	_, _ = scanner.Read(buf)
	lines := strings.Split(string(buf), "\n")
	for i, line := range lines {
		if i == 0 || line == "" {
			continue // header or trailing blank
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		// Destination (col 1) = "00000000" means default; Gateway (col 2)
		// is our target.
		if fields[1] == "00000000" && strings.EqualFold(fields[2], wantHex) {
			return true
		}
	}
	return false
}

// ipv4ToLittleEndianHex converts a dotted-quad IPv4 string to the
// 8-char uppercase hex representation used in /proc/net/route.
// Returns "" for malformed input.
func ipv4ToLittleEndianHex(ip string) string {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return ""
	}
	b := make([]byte, 4)
	for i, part := range parts {
		var val int
		if _, err := fmt.Sscanf(part, "%d", &val); err != nil || val < 0 || val > 255 {
			return ""
		}
		b[3-i] = byte(val) // little-endian
	}
	return fmt.Sprintf("%02X%02X%02X%02X", b[0], b[1], b[2], b[3])
}

// operstateReady returns true when /sys/class/net/eth0/operstate
// reports "up" or "unknown" (some drivers don't transition cleanly
// but the link is usable).
func operstateReady() bool {
	data, err := os.ReadFile("/sys/class/net/eth0/operstate")
	if err != nil {
		return false
	}
	state := string(bytes.TrimSpace(data))
	return state == "up" || state == "unknown"
}

// carrierUp returns true when /sys/class/net/eth0/carrier is "1".
func carrierUp() bool {
	data, err := os.ReadFile("/sys/class/net/eth0/carrier")
	if err != nil {
		return false
	}
	trimmed := bytes.TrimSpace(data)
	return len(trimmed) > 0 && trimmed[0] == '1'
}
