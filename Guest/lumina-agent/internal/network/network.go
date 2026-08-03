// Package network applies host-driven network configuration, then
// verifies the route table and polls for carrier before sending
// network_ready to the host. v0.7.1 reliability pass: individual
// ip-command retries, post-setup route verification, explicit
// error reporting on failure.
//
// v0.7.2 reliability pass: the target interface is discovered at
// runtime instead of hard-coded to "eth0". Images that use systemd
// predictable names (enp0s1, ens3) or that enumerate virtio-net as
// a non-eth0 name on first boot now configure cleanly. Fallback is
// "eth0" so existing images keep working.
//
// v0.7.3 correctness pass: dropped the `ip -batch` fast path (BusyBox
// has no -batch, so it failed on every boot), and readiness now
// requires an address as well as a route — see configured().
package network

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// maxCarrierWait is the upper bound on how long we poll /sys/class/net
// for link-up. v0.7.1 perf: dropped from 2s → 400ms after profiling
// showed VZ NAT brings the interface up in 40–80ms (P95 ~120ms) on M3
// hosts. The 400ms ceiling covers the worst case observed; if it times
// out, we emit network_ready with Stage="timeout-anyway" so the host
// can treat it as a softer signal.
const maxCarrierWait = 400 * time.Millisecond

// carrierPollInterval is the sysfs read cadence. 5ms gives us
// 8-16 poll ticks on the typical 50-80ms carrier-up latency, without
// measurably costing anything (open(2)+read(2)+close(2) = ~5µs).
const carrierPollInterval = 5 * time.Millisecond

// ipRetryAttempts caps how many times we re-apply and re-verify when the
// address or default route doesn't commit (transient EBUSY on concurrent
// netlink ops).
const ipRetryAttempts = 3

// ipRetryBackoff is the linear backoff between ip retries.
const ipRetryBackoff = 20 * time.Millisecond

// fallbackInterface is the interface name used if /sys/class/net is
// unreadable or contains nothing that looks like an ethernet device.
// Matches the pre-v0.7.2 hard-coded default — images that relied on
// it still work.
const fallbackInterface = "eth0"

// Injection points for tests. These are package-level vars rather
// than struct fields because Configure is a free function; tests
// substitute them directly. In production they always point at the
// defaults below.
var (
	runIP         func(iface string, args ...string) error               = defaultRunIP
	readRouteFile func() ([]byte, error)                                 = defaultReadRouteFile
	readIfaceIPv4 func(iface string) string                              = defaultReadIfaceIPv4
	pickInterface func() string                                          = defaultPickInterface
	readNetSysfs  func(iface, file string) ([]byte, error)               = defaultReadNetSysfs
	clock         func() time.Time                                       = time.Now
	mkdirAll      func(path string, perm os.FileMode) error              = os.MkdirAll
	writeFile     func(path string, data []byte, perm os.FileMode) error = os.WriteFile
	readFile      func(path string) ([]byte, error)                      = os.ReadFile
)

// resolvConfPath is where DNS config lands on the guest.
const resolvConfPath = "/etc/resolv.conf"

// configureDNS writes resolvConfPath and reads it back to confirm the
// write actually landed, rather than trusting a nil error from
// WriteFile — a read-only overlay or full disk can both return nil
// from the mkdir/write calls on some filesystems while the content
// never persists. Returns false (network_ready's DnsOk) on any
// mismatch so the host learns DNS is broken instead of finding out at
// the first getaddrinfo call.
func configureDNS(dns string) bool {
	if err := mkdirAll("/etc", 0o755); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "resolv.conf mkdir /etc: %v (continuing; DNS lookups will fail)\n", err)
		return false
	}
	content := []byte("nameserver " + dns + "\n")
	if err := writeFile(resolvConfPath, content, 0o644); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "resolv.conf write: %v (continuing; DNS lookups will fail)\n", err)
		return false
	}
	got, err := readFile(resolvConfPath)
	if err != nil || !bytes.Equal(got, content) {
		_, _ = fmt.Fprintf(os.Stderr, "resolv.conf readback mismatch after write (continuing; DNS lookups may fail): err=%v\n", err)
		return false
	}
	return true
}

// Configure applies msg to the primary ethernet interface (IP/route/DNS)
// with retries, verifies the routing table reflects the requested
// default route, then polls for carrier and sends NetworkReadyMsg. On
// hard failure (setup couldn't complete even with retries), sends
// NetworkErrorMsg and returns — the host-side caller sees a typed
// error, not a silent best-effort success.
func Configure(w *wire.Writer, msg protocol.ConfigureNetworkMsg) {
	started := clock()
	iface := pickInterface()
	_, _ = fmt.Fprintf(os.Stderr, "configuring network on %s: ip=%s gw=%s dns=%s\n",
		iface, msg.IP, msg.Gateway, msg.DNS)

	// VZ NAT is IPv4-only; disable IPv6 so the guest doesn't waste
	// time discovering a missing router. Cheap — a single writev.
	_ = os.WriteFile("/proc/sys/net/ipv6/conf/all/disable_ipv6", []byte("1"), 0o644)

	// Retry with linear backoff: `route replace` can return 0 without
	// committing when netlink is busy with a concurrent op.
	attempts := 0
	var lastErr error
	for {
		attempts++
		if err := applyConfig(iface, msg.IP, msg.Gateway); err != nil {
			lastErr = err
		}
		if configured(iface, msg.Gateway) || attempts >= ipRetryAttempts {
			break
		}
		time.Sleep(ipRetryBackoff * time.Duration(attempts))
	}

	if !configured(iface, msg.Gateway) {
		reason := "address or default route not installed after retries"
		if lastErr != nil {
			reason = lastErr.Error()
		}
		_, _ = fmt.Fprintf(os.Stderr, "network setup failed on %s after %d attempts: %s\n",
			iface, attempts, reason)
		_ = w.Send(protocol.NetworkErrorMsg{
			Type:     protocol.TypeNetworkError,
			Reason:   reason,
			Attempts: attempts,
		})
		return
	}

	// Step 2: DNS. The write is attempted even on a resolv.conf we
	// can't verify — a read-only /etc or a full disk means DNS
	// lookups will fail, but the route/IP can still be usable for
	// direct-IP traffic. dnsOk is reported on network_ready instead
	// of assumed, since await-network-ready exists specifically to
	// guarantee DNS is live before the first exec.
	dnsOk := configureDNS(msg.DNS)

	// Report the address the interface actually holds, not the one the
	// host asked for: they diverge whenever something else on the guest
	// (a DHCP client in a legacy image, a user's netplan) got there
	// first, and a host that trusts the request has no way to notice.
	actualIP := readIfaceIPv4(iface)

	deadline := started.Add(maxCarrierWait)
	for clock().Before(deadline) {
		if operstateReady(iface) {
			elapsed := clock().Sub(started)
			_, _ = fmt.Fprintf(os.Stderr, "network operstate up on %s after %s\n", iface, elapsed)
			_ = w.Send(protocol.NetworkReadyMsg{
				Type:     protocol.TypeNetworkReady,
				IP:       actualIP,
				ConfigMs: int(elapsed.Milliseconds()),
				Stage:    "operstate",
				DnsOk:    dnsOk,
			})
			return
		}
		if carrierUp(iface) {
			elapsed := clock().Sub(started)
			_, _ = fmt.Fprintf(os.Stderr, "network carrier up on %s after %s\n", iface, elapsed)
			_ = w.Send(protocol.NetworkReadyMsg{
				Type:     protocol.TypeNetworkReady,
				IP:       actualIP,
				ConfigMs: int(elapsed.Milliseconds()),
				Stage:    "carrier",
				DnsOk:    dnsOk,
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
	elapsed := clock().Sub(started)
	_, _ = fmt.Fprintf(os.Stderr, "network readiness timeout on %s after %s; route verified, shipping network_ready (stage=timeout-anyway)\n",
		iface, elapsed)
	_ = w.Send(protocol.NetworkReadyMsg{
		Type:     protocol.TypeNetworkReady,
		IP:       actualIP,
		ConfigMs: int(elapsed.Milliseconds()),
		Stage:    "timeout-anyway",
		DnsOk:    dnsOk,
	})
}

// defaultPickInterface enumerates /sys/class/net and returns the
// primary ethernet-style interface. Order of preference:
//  1. Any interface whose /sys/class/net/<name>/device/modalias
//     starts with "virtio:" — this is the VZ virtio-net device,
//     unambiguous when present.
//  2. Any interface named like en* or eth* that is not a bridge,
//     vlan, tap, tun, docker, or loopback. Handles kernel-named
//     enp0s1, ens3, enX0 alongside the classic eth0.
//  3. Any remaining non-loopback, non-virtual interface.
//  4. Fallback: the literal string "eth0" — keeps old images that
//     genuinely expose eth0 working if sysfs enumeration fails for
//     any reason (unreadable, container environment, etc.).
//
// Called once per Configure invocation. No caching — cheap enough
// (a handful of sysfs reads) and avoids a whole class of "stale
// after interface rename" bugs.
func defaultPickInterface() string {
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return fallbackInterface
	}

	names := make([]string, 0, len(entries))
	for _, e := range entries {
		n := e.Name()
		if n == "" || n == "lo" {
			continue
		}
		names = append(names, n)
	}
	// Deterministic order so the choice is stable across boots even
	// when readdir order is not.
	sort.Strings(names)

	// Pass 1: virtio-net modalias is the ground truth on a VZ guest.
	for _, n := range names {
		data, err := readNetSysfs(n, "device/modalias")
		if err != nil {
			continue
		}
		if bytes.HasPrefix(bytes.TrimSpace(data), []byte("virtio:")) {
			// Double-check it's an ethernet device (virtio has many
			// personalities: net, block, console, rng…). The kernel
			// exposes net devices under /sys/class/net, so presence
			// here is already a strong signal, but require the type
			// file to read as ARPHRD_ETHER (1) to be safe.
			if isEthernet(n) {
				return n
			}
		}
	}

	// Pass 2: predictable naming + classic eth* names.
	for _, n := range names {
		if !looksLikeEthernet(n) {
			continue
		}
		if isVirtualInterface(n) {
			continue
		}
		if isEthernet(n) {
			return n
		}
	}

	// Pass 3: anything else that is an ethernet device and not
	// obviously virtual.
	for _, n := range names {
		if isVirtualInterface(n) {
			continue
		}
		if isEthernet(n) {
			return n
		}
	}

	return fallbackInterface
}

// looksLikeEthernet filters by name pattern only — cheap, no I/O.
// Matches en*, eth*, enX* (predictable naming), enp*, ens*, eno*.
func looksLikeEthernet(name string) bool {
	if strings.HasPrefix(name, "eth") {
		return true
	}
	if strings.HasPrefix(name, "en") {
		return true
	}
	return false
}

// isVirtualInterface rejects bridges, tap devices, docker links,
// wireguard tunnels, and the like. These are userspace-created
// and should never be the VZ guest's primary NIC.
func isVirtualInterface(name string) bool {
	switch {
	case strings.HasPrefix(name, "br"):
		return true
	case strings.HasPrefix(name, "docker"):
		return true
	case strings.HasPrefix(name, "veth"):
		return true
	case strings.HasPrefix(name, "tap"):
		return true
	case strings.HasPrefix(name, "tun"):
		return true
	case strings.HasPrefix(name, "wg"):
		return true
	case strings.HasPrefix(name, "vnet"):
		return true
	}
	return false
}

// isEthernet reads /sys/class/net/<name>/type and confirms it
// reports ARPHRD_ETHER (1). Filters out anything Linux exposes as
// a netdev that is not actually ethernet (ppp, ipip, sit).
func isEthernet(name string) bool {
	data, err := readNetSysfs(name, "type")
	if err != nil {
		return false
	}
	return bytes.Equal(bytes.TrimSpace(data), []byte("1"))
}

// applyConfig brings iface up and installs the address and default route.
//
// Three separate `ip` invocations on purpose. v0.7.1 folded them into one
// `ip -batch -` to save two forks; BusyBox `ip` — what the shipped guest
// image actually has — has no -batch and exited 1 with a usage dump on
// every boot, so that fast path never once succeeded. Two forks cost ~1ms.
// Do not re-batch without checking `ip -V` in the target image.
func applyConfig(iface, ip, gateway string) error {
	if err := runIP(iface, "link", "set", iface, "up"); err != nil {
		return fmt.Errorf("link up: %w", err)
	}
	// BusyBox reports "File exists" when already assigned; configured()
	// is the real gate, so this alone is not fatal.
	addrErr := runIP(iface, "addr", "add", ip, "dev", iface)
	if err := runIP(iface, "route", "replace", "default", "via", gateway); err != nil {
		if addrErr != nil {
			return fmt.Errorf("addr add: %v; route replace: %w", addrErr, err)
		}
		return fmt.Errorf("route replace: %w", err)
	}
	return nil
}

// configured reports whether iface can actually send a packet. Checking
// only the route lets one installed by someone else count as success
// while the interface still has no address.
func configured(iface, gateway string) bool {
	return readIfaceIPv4(iface) != "" && routeVerified(gateway)
}

// defaultReadIfaceIPv4 returns the first global IPv4 address on iface, or "".
func defaultReadIfaceIPv4(iface string) string {
	ifi, err := net.InterfaceByName(iface)
	if err != nil {
		return ""
	}
	addrs, err := ifi.Addrs()
	if err != nil {
		return ""
	}
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		v4 := ipnet.IP.To4()
		if v4 == nil || v4.IsLoopback() || v4.IsLinkLocalUnicast() {
			continue
		}
		return v4.String()
	}
	return ""
}

// defaultRunIP runs a single `ip` command and returns any error along with
// stderr context for diagnostics. The `iface` parameter is present for
// symmetry with runIPBatch and to make test injection uniform; the real
// implementation doesn't need it because the caller already wove the
// interface name into args.
func defaultRunIP(_ string, args ...string) error {
	cmd := exec.Command("ip", args...)
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ip %s: %w (stderr=%q)",
			strings.Join(args, " "), err, errBuf.String())
	}
	return nil
}

// defaultReadRouteFile reads /proc/net/route. Split out so tests can
// supply a synthetic route table.
func defaultReadRouteFile() ([]byte, error) {
	return os.ReadFile("/proc/net/route")
}

// defaultReadNetSysfs reads a file under /sys/class/net/<iface>/.
// Split out so tests can supply synthetic sysfs state without
// mounting a fake tree.
func defaultReadNetSysfs(iface, file string) ([]byte, error) {
	return os.ReadFile("/sys/class/net/" + iface + "/" + file)
}

// routeVerified checks that the default route in the kernel's
// routing table points to `gateway`. Reads /proc/net/route rather
// than spawning `ip route` for a ~3× speedup (no fork/exec).
//
// The file format is:
//
//	Iface  Destination  Gateway   Flags  RefCnt  Use  Metric  Mask  MTU  Window  IRTT
//	eth0   00000000     0140A8C0  0003   0       0    0       00000000  0    0       0
//
// Destination=00000000 is the default (0.0.0.0) route; Gateway is
// little-endian hex (0140A8C0 → 192.168.64.1). The interface name
// is not checked — we only care that the default route points at
// the gateway we requested.
func routeVerified(gateway string) bool {
	data, err := readRouteFile()
	if err != nil {
		return false
	}
	wantHex := ipv4ToLittleEndianHex(gateway)
	if wantHex == "" {
		return false
	}
	// /proc/net/route is typically <1KB. bytes.Split + bytes.Fields
	// is one allocation (the line slice) with no string copies of
	// the file body — simpler than wrapping in bytes.NewReader.
	for i, line := range bytes.Split(data, []byte{'\n'}) {
		if i == 0 || len(line) == 0 {
			continue // header or trailing blank
		}
		fields := bytes.Fields(line)
		if len(fields) < 3 {
			continue
		}
		// Destination (col 1) = "00000000" means default; Gateway (col 2)
		// is our target.
		if bytes.Equal(fields[1], []byte("00000000")) &&
			bytes.EqualFold(fields[2], []byte(wantHex)) {
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
		if part == "" {
			return ""
		}
		var val int
		if _, err := fmt.Sscanf(part, "%d", &val); err != nil || val < 0 || val > 255 {
			return ""
		}
		// Reject leading-zero or trailing-junk inputs that Sscanf
		// accepts but aren't valid dotted-quad octets.
		if fmt.Sprintf("%d", val) != part {
			return ""
		}
		b[3-i] = byte(val) // little-endian
	}
	return fmt.Sprintf("%02X%02X%02X%02X", b[0], b[1], b[2], b[3])
}

// operstateReady returns true when /sys/class/net/<iface>/operstate
// reports "up" or "unknown" (some drivers don't transition cleanly
// but the link is usable).
func operstateReady(iface string) bool {
	data, err := readNetSysfs(iface, "operstate")
	if err != nil {
		return false
	}
	state := string(bytes.TrimSpace(data))
	return state == "up" || state == "unknown"
}

// carrierUp returns true when /sys/class/net/<iface>/carrier is "1".
func carrierUp(iface string) bool {
	data, err := readNetSysfs(iface, "carrier")
	if err != nil {
		return false
	}
	trimmed := bytes.TrimSpace(data)
	return len(trimmed) > 0 && trimmed[0] == '1'
}
