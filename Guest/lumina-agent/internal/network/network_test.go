package network

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

func TestIPv4ToLittleEndianHex(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		// Well-known mapping: the /proc/net/route docs use this exact
		// example for the VZ NAT gateway.
		{"192.168.64.1", "0140A8C0"},
		{"0.0.0.0", "00000000"},
		{"255.255.255.255", "FFFFFFFF"},
		{"10.0.0.1", "0100000A"},
		{"127.0.0.1", "0100007F"},

		// Malformed inputs must round-trip to "" so routeVerified
		// refuses to match on them instead of accidentally parsing
		// a partial address.
		{"", ""},
		{"1.2.3", ""},
		{"1.2.3.4.5", ""},
		{"256.0.0.1", ""},
		{"-1.0.0.1", ""},
		{"a.b.c.d", ""},
		{"1.2.3.", ""},
		{".1.2.3", ""},
		{"01.2.3.4", ""}, // leading zeros are ambiguous — reject
	}
	for _, c := range cases {
		got := ipv4ToLittleEndianHex(c.in)
		if got != c.want {
			t.Errorf("ipv4ToLittleEndianHex(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

const sampleRouteFile = `Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
eth0	00000000	0140A8C0	0003	0	0	0	00000000	0	0	0
eth0	0040A8C0	00000000	0001	0	0	0	00FFFFFF	0	0	0
`

func TestRouteVerified_matchesDefaultGateway(t *testing.T) {
	readRouteFile = func() ([]byte, error) { return []byte(sampleRouteFile), nil }
	defer func() { readRouteFile = defaultReadRouteFile }()

	if !routeVerified("192.168.64.1") {
		t.Fatalf("expected default route to match 192.168.64.1")
	}
}

func TestRouteVerified_rejectsWrongGateway(t *testing.T) {
	readRouteFile = func() ([]byte, error) { return []byte(sampleRouteFile), nil }
	defer func() { readRouteFile = defaultReadRouteFile }()

	if routeVerified("192.168.64.2") {
		t.Fatalf("expected default route NOT to match 192.168.64.2")
	}
}

func TestRouteVerified_missingFile(t *testing.T) {
	readRouteFile = func() ([]byte, error) { return nil, errors.New("no such file") }
	defer func() { readRouteFile = defaultReadRouteFile }()

	if routeVerified("192.168.64.1") {
		t.Fatalf("expected false when /proc/net/route cannot be read")
	}
}

func TestRouteVerified_emptyFile(t *testing.T) {
	readRouteFile = func() ([]byte, error) { return []byte(""), nil }
	defer func() { readRouteFile = defaultReadRouteFile }()

	if routeVerified("192.168.64.1") {
		t.Fatalf("expected false on empty route file")
	}
}

func TestRouteVerified_headerOnly(t *testing.T) {
	readRouteFile = func() ([]byte, error) {
		return []byte("Iface\tDestination\tGateway\tFlags\n"), nil
	}
	defer func() { readRouteFile = defaultReadRouteFile }()

	if routeVerified("192.168.64.1") {
		t.Fatalf("expected false when only a header line is present")
	}
}

func TestRouteVerified_malformedGateway(t *testing.T) {
	readRouteFile = func() ([]byte, error) { return []byte(sampleRouteFile), nil }
	defer func() { readRouteFile = defaultReadRouteFile }()

	if routeVerified("not-an-ip") {
		t.Fatalf("expected false on malformed gateway input")
	}
	if routeVerified("") {
		t.Fatalf("expected false on empty gateway input")
	}
}

func TestRouteVerified_acceptsMixedCaseHex(t *testing.T) {
	// Some kernels emit lowercase hex. Ensure we match case-insensitively.
	routeLower := strings.Replace(sampleRouteFile, "0140A8C0", "0140a8c0", 1)
	readRouteFile = func() ([]byte, error) { return []byte(routeLower), nil }
	defer func() { readRouteFile = defaultReadRouteFile }()

	if !routeVerified("192.168.64.1") {
		t.Fatalf("expected case-insensitive match on lowercase hex gateway")
	}
}

// TestStubsWireUp smoke-tests the injection points so an accidental
// shadowing of the package vars by a future refactor fails loud. The
// integration behaviour of Configure() (carrier-wait + wire send)
// would need wire.Writer abstracted behind an interface to test
// end-to-end; the tests above cover the deterministic parsing and
// lookup layers the reliability fix actually depends on.
func TestStubsWireUp(t *testing.T) {
	origSingle, origRoute, origAddr := runIP, readRouteFile, readIfaceIPv4
	defer func() {
		runIP = origSingle
		readRouteFile = origRoute
		readIfaceIPv4 = origAddr
	}()

	runIP = func(_ string, _ ...string) error { return nil }
	readRouteFile = func() ([]byte, error) { return []byte(sampleRouteFile), nil }
	readIfaceIPv4 = func(_ string) string { return "192.168.64.2" }

	if err := runIP("eth0", "link", "set", "eth0", "up"); err != nil {
		t.Fatalf("stubbed runIP should return nil, got %v", err)
	}
	if data, err := readRouteFile(); err != nil || len(data) == 0 {
		t.Fatalf("stubbed readRouteFile should return sample data, got err=%v len=%d", err, len(data))
	}
	if got := readIfaceIPv4("eth0"); got != "192.168.64.2" {
		t.Fatalf("stubbed readIfaceIPv4 = %q, want 192.168.64.2", got)
	}
}

// applyConfig must never invoke `ip -batch`. The shipped guest image
// uses BusyBox `ip`, which has no -batch subcommand: it exits 1 with a
// usage dump, so the batched fast path introduced in v0.7.1 failed on
// every single boot and silently degraded to the retry path. Assert on
// the argv so a future "let's batch it again" refactor fails here
// instead of in production.
func TestApplyConfig_issuesIndividualBusyBoxCommands(t *testing.T) {
	orig := runIP
	defer func() { runIP = orig }()

	var calls [][]string
	runIP = func(_ string, args ...string) error {
		calls = append(calls, args)
		return nil
	}

	if err := applyConfig("eth0", "192.168.64.2/24", "192.168.64.1"); err != nil {
		t.Fatalf("applyConfig returned %v, want nil", err)
	}

	want := [][]string{
		{"link", "set", "eth0", "up"},
		{"addr", "add", "192.168.64.2/24", "dev", "eth0"},
		{"route", "replace", "default", "via", "192.168.64.1"},
	}
	if len(calls) != len(want) {
		t.Fatalf("got %d ip invocations %v, want %d", len(calls), calls, len(want))
	}
	for i := range want {
		if strings.Join(calls[i], " ") != strings.Join(want[i], " ") {
			t.Errorf("call %d = %v, want %v", i, calls[i], want[i])
		}
		if calls[i][0] == "-batch" {
			t.Errorf("call %d uses `ip -batch`, unsupported by BusyBox", i)
		}
	}
}

// An address that already exists makes BusyBox `ip addr add` exit
// non-zero ("File exists"). That is benign — configuring twice is a
// no-op, not a failure — so applyConfig must not surface it as long as
// the route command lands.
func TestApplyConfig_tolerantOfExistingAddress(t *testing.T) {
	orig := runIP
	defer func() { runIP = orig }()

	runIP = func(_ string, args ...string) error {
		if args[0] == "addr" {
			return errors.New("ip addr add: File exists")
		}
		return nil
	}

	if err := applyConfig("eth0", "192.168.64.2/24", "192.168.64.1"); err != nil {
		t.Fatalf("applyConfig should tolerate an existing address, got %v", err)
	}
}

// When the route command fails, the address error is folded into the
// message so network_error names the root cause rather than the
// downstream symptom.
func TestApplyConfig_reportsRouteFailureWithAddrContext(t *testing.T) {
	orig := runIP
	defer func() { runIP = orig }()

	runIP = func(_ string, args ...string) error {
		switch args[0] {
		case "addr":
			return errors.New("permission denied")
		case "route":
			return errors.New("network is unreachable")
		}
		return nil
	}

	err := applyConfig("eth0", "192.168.64.2/24", "192.168.64.1")
	if err == nil {
		t.Fatal("expected an error when route replace fails")
	}
	if !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("error %q should carry the addr-add context", err)
	}
	if !strings.Contains(err.Error(), "network is unreachable") {
		t.Errorf("error %q should carry the route-replace cause", err)
	}
}

// configured() is the gate that decides whether network_ready or
// network_error goes on the wire. Before v0.7.3 it checked the default
// route only, so a route installed by anything other than us (a DHCP
// client, a leftover from a previous configure) counted as success
// while the interface still had no address — the guest then reported
// ready with no way to send a packet. Both halves must hold.
func TestConfigured_requiresAddressAndRoute(t *testing.T) {
	origRoute, origAddr := readRouteFile, readIfaceIPv4
	defer func() {
		readRouteFile = origRoute
		readIfaceIPv4 = origAddr
	}()

	cases := []struct {
		name  string
		addr  string
		route string
		want  bool
	}{
		{"address and route", "192.168.64.2", sampleRouteFile, true},
		{"route but no address", "", sampleRouteFile, false},
		{"address but no route", "192.168.64.2", "", false},
		{"neither", "", "", false},
	}
	for _, c := range cases {
		readIfaceIPv4 = func(_ string) string { return c.addr }
		readRouteFile = func() ([]byte, error) { return []byte(c.route), nil }
		if got := configured("eth0", "192.168.64.1"); got != c.want {
			t.Errorf("%s: configured() = %v, want %v", c.name, got, c.want)
		}
	}
}

// sysfsStub returns a readNetSysfs implementation that reads from
// an in-memory map keyed "<iface>/<file>". Missing keys return
// os.ErrNotExist-equivalent behaviour.
func sysfsStub(entries map[string]string) func(string, string) ([]byte, error) {
	return func(iface, file string) ([]byte, error) {
		key := iface + "/" + file
		if v, ok := entries[key]; ok {
			return []byte(v), nil
		}
		return nil, errors.New("no such file: " + key)
	}
}

func TestPickInterface_prefersVirtioEthernet(t *testing.T) {
	// A VZ guest typically exposes a single virtio-net device; the
	// primary pass should resolve it regardless of kernel-assigned
	// name.
	orig := readNetSysfs
	readNetSysfsOverride := sysfsStub(map[string]string{
		"enp0s1/device/modalias": "virtio:d00000001v00001AF4",
		"enp0s1/type":            "1",
	})
	readNetSysfs = readNetSysfsOverride
	defer func() { readNetSysfs = orig }()

	// Shim ReadDir via a one-off: defaultPickInterface reads
	// /sys/class/net directly, so to keep this test hermetic we
	// call the underlying helpers instead of exercising the real
	// filesystem walk. The integration path is covered in CI by
	// the real VM boot.
	if !isEthernet("enp0s1") {
		t.Fatalf("virtio-net ethernet device should register as type=1")
	}
}

func TestLooksLikeEthernet(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{"eth0", true},
		{"eth1", true},
		{"en0", true},
		{"enp0s1", true},
		{"ens3", true},
		{"eno1", true},
		{"lo", false},
		{"wlan0", false},
		{"docker0", false}, // note: isVirtualInterface catches this separately
		{"br0", false},
		{"tap0", false},
	}
	for _, c := range cases {
		if got := looksLikeEthernet(c.name); got != c.want {
			t.Errorf("looksLikeEthernet(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestIsVirtualInterface(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{"br0", true},
		{"bridge100", true},
		{"docker0", true},
		{"veth0abc", true},
		{"tap0", true},
		{"tun0", true},
		{"wg0", true},
		{"vnet0", true},
		{"eth0", false},
		{"enp0s1", false},
		{"en0", false},
	}
	for _, c := range cases {
		if got := isVirtualInterface(c.name); got != c.want {
			t.Errorf("isVirtualInterface(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestIsEthernet_readsTypeFile(t *testing.T) {
	orig := readNetSysfs
	defer func() { readNetSysfs = orig }()

	readNetSysfs = sysfsStub(map[string]string{
		"eth0/type": "1\n",
		"ppp0/type": "512", // ARPHRD_PPP
	})

	if !isEthernet("eth0") {
		t.Errorf("eth0 with type=1 should be ethernet")
	}
	if isEthernet("ppp0") {
		t.Errorf("ppp0 with type=512 should not be ethernet")
	}
	if isEthernet("missing") {
		t.Errorf("missing interface should not be ethernet")
	}
}

func TestOperstateReady_acceptsUpAndUnknown(t *testing.T) {
	orig := readNetSysfs
	defer func() { readNetSysfs = orig }()

	readNetSysfs = sysfsStub(map[string]string{
		"eth0/operstate":   "up\n",
		"enp0s1/operstate": "unknown",
		"eth1/operstate":   "down",
	})

	if !operstateReady("eth0") {
		t.Errorf("operstate=up should be ready")
	}
	if !operstateReady("enp0s1") {
		t.Errorf("operstate=unknown should be ready (some drivers never transition)")
	}
	if operstateReady("eth1") {
		t.Errorf("operstate=down should not be ready")
	}
	if operstateReady("missing") {
		t.Errorf("missing sysfs should not be ready")
	}
}

func TestCarrierUp(t *testing.T) {
	orig := readNetSysfs
	defer func() { readNetSysfs = orig }()

	readNetSysfs = sysfsStub(map[string]string{
		"eth0/carrier":   "1\n",
		"enp0s1/carrier": "1",
		"eth1/carrier":   "0",
	})

	if !carrierUp("eth0") {
		t.Errorf("carrier=1 should be up")
	}
	if !carrierUp("enp0s1") {
		t.Errorf("carrier=1 (no newline) should be up")
	}
	if carrierUp("eth1") {
		t.Errorf("carrier=0 should not be up")
	}
	if carrierUp("missing") {
		t.Errorf("missing sysfs should not be up")
	}
}

// configureDNS is the postcondition check for the whole reason
// awaitNetworkReady exists: DNS must be live before the first exec.
// Before this fix, a failed mkdir/write was logged to stderr (if at
// all) and network_ready shipped regardless — callers found out at
// the first getaddrinfo NXDOMAIN.
func TestConfigureDNS(t *testing.T) {
	origMkdir, origWrite, origRead := mkdirAll, writeFile, readFile
	defer func() { mkdirAll, writeFile, readFile = origMkdir, origWrite, origRead }()

	cases := []struct {
		name     string
		mkdirErr error
		writeErr error
		readBack []byte
		readErr  error
		want     bool
	}{
		{name: "write and readback succeed", readBack: []byte("nameserver 8.8.8.8\n"), want: true},
		{name: "mkdir fails", mkdirErr: errors.New("read-only filesystem"), want: false},
		{name: "write fails", writeErr: errors.New("no space left on device"), want: false},
		{name: "readback fails", readErr: errors.New("permission denied"), want: false},
		{name: "readback content mismatch", readBack: []byte("nameserver 1.1.1.1\n"), want: false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mkdirAll = func(_ string, _ os.FileMode) error { return c.mkdirErr }
			var gotContent []byte
			writeFile = func(_ string, data []byte, _ os.FileMode) error {
				gotContent = data
				return c.writeErr
			}
			readFile = func(_ string) ([]byte, error) {
				if c.readErr != nil {
					return nil, c.readErr
				}
				return c.readBack, nil
			}

			if got := configureDNS("8.8.8.8"); got != c.want {
				t.Errorf("configureDNS() = %v, want %v", got, c.want)
			}
			if c.mkdirErr == nil && c.writeErr == nil && string(gotContent) != "nameserver 8.8.8.8\n" {
				t.Errorf("wrote %q, want %q", gotContent, "nameserver 8.8.8.8\n")
			}
		})
	}
}

// TestConfigure_ReportsDnsOkOnWireEnvelope drives Configure() end to
// end over a real net.Pipe-backed wire.Writer and asserts the dns_ok
// field on network_ready reflects whether resolv.conf actually landed
// — not just whether the interface came up. Before this fix,
// network_ready shipped unconditionally regardless of DNS state.
func TestConfigure_ReportsDnsOkOnWireEnvelope(t *testing.T) {
	origRunIP, origRoute, origAddr := runIP, readRouteFile, readIfaceIPv4
	origPick, origSysfs, origClock := pickInterface, readNetSysfs, clock
	origMkdir, origWrite, origRead := mkdirAll, writeFile, readFile
	defer func() {
		runIP, readRouteFile, readIfaceIPv4 = origRunIP, origRoute, origAddr
		pickInterface, readNetSysfs, clock = origPick, origSysfs, origClock
		mkdirAll, writeFile, readFile = origMkdir, origWrite, origRead
	}()

	runIP = func(_ string, _ ...string) error { return nil }
	readRouteFile = func() ([]byte, error) { return []byte(sampleRouteFile), nil }
	readIfaceIPv4 = func(_ string) string { return "192.168.64.2" }
	pickInterface = func() string { return "eth0" }
	readNetSysfs = sysfsStub(map[string]string{"eth0/operstate": "up"})
	fixed := time.Now()
	clock = func() time.Time { return fixed } // freezes the carrier-wait loop to one pass

	cases := []struct {
		name      string
		writeErr  error
		wantDnsOk bool
	}{
		{"dns write succeeds", nil, true},
		{"dns write fails", errors.New("read-only filesystem"), false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mkdirAll = func(_ string, _ os.FileMode) error { return nil }
			writeFile = func(_ string, _ []byte, _ os.FileMode) error { return c.writeErr }
			readFile = func(_ string) ([]byte, error) { return []byte("nameserver 192.168.64.1\n"), nil }

			hostConn, guestConn := net.Pipe()
			defer hostConn.Close()
			defer guestConn.Close()
			w := wire.NewWriter(guestConn)

			msgCh := make(chan map[string]any, 1)
			go func() {
				scanner := bufio.NewScanner(hostConn)
				if scanner.Scan() {
					var m map[string]any
					_ = json.Unmarshal(scanner.Bytes(), &m)
					msgCh <- m
				}
			}()

			Configure(w, protocol.ConfigureNetworkMsg{
				Type: protocol.TypeConfigureNetwork, IP: "192.168.64.2/24",
				Gateway: "192.168.64.1", DNS: "192.168.64.1",
			})

			got := <-msgCh
			if got["type"] != "network_ready" {
				t.Fatalf("expected network_ready, got %v", got)
			}
			if got["dns_ok"] != c.wantDnsOk {
				t.Errorf("dns_ok = %v, want %v", got["dns_ok"], c.wantDnsOk)
			}
		})
	}
}
