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

	runIPBatch = func(ip, gateway string) (bool, string) { return true, "" }
	runIP = func(args ...string) error { return nil }
	readRouteFile = func() ([]byte, error) { return []byte(sampleRouteFile), nil }

	if ok, _ := runIPBatch("1.2.3.4/24", "1.2.3.1"); !ok {
		t.Fatalf("stubbed runIPBatch should return true")
	}
	if err := runIP("link", "set", "eth0", "up"); err != nil {
		t.Fatalf("stubbed runIP should return nil, got %v", err)
	}
	if data, err := readRouteFile(); err != nil || len(data) == 0 {
		t.Fatalf("stubbed readRouteFile should return sample data, got err=%v len=%d", err, len(data))
	}
}
