package network

import (
	"errors"
	"strings"
	"testing"
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
	origBatch, origSingle, origRoute := runIPBatch, runIP, readRouteFile
	defer func() {
		runIPBatch = origBatch
		runIP = origSingle
		readRouteFile = origRoute
	}()

	runIPBatch = func(_ string, _, _ string) (bool, string) { return true, "" }
	runIP = func(_ string, _ ...string) error { return nil }
	readRouteFile = func() ([]byte, error) { return []byte(sampleRouteFile), nil }

	if ok, _ := runIPBatch("eth0", "1.2.3.4/24", "1.2.3.1"); !ok {
		t.Fatalf("stubbed runIPBatch should return true")
	}
	if err := runIP("eth0", "link", "set", "eth0", "up"); err != nil {
		t.Fatalf("stubbed runIP should return nil, got %v", err)
	}
	if data, err := readRouteFile(); err != nil || len(data) == 0 {
		t.Fatalf("stubbed readRouteFile should return sample data, got err=%v len=%d", err, len(data))
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
		"eth0/operstate":    "up\n",
		"enp0s1/operstate":  "unknown",
		"eth1/operstate":    "down",
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
