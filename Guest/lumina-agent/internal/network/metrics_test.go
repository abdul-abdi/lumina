package network

import "testing"

// Real-world /proc/net/dev sample captured from a running VZ-NAT Alpine VM.
const sampleProcNetDev = `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:     312       3    0    0    0     0          0         0      312       3    0    0    0     0       0          0
  eth0:   12345     100    1    0    0     0          0         0    67890     200    2    0    0     0       0          0
`

func TestParseProcNetDev_excludesLoopback(t *testing.T) {
	ifaces := parseProcNetDev([]byte(sampleProcNetDev))
	if _, ok := ifaces["lo"]; ok {
		t.Fatalf("loopback must be excluded; got entry: %+v", ifaces["lo"])
	}
}

func TestParseProcNetDev_eth0Counters(t *testing.T) {
	ifaces := parseProcNetDev([]byte(sampleProcNetDev))
	eth0, ok := ifaces["eth0"]
	if !ok {
		t.Fatalf("eth0 missing; got %+v", ifaces)
	}
	// Rx columns: bytes(0) packets(1) errs(2)
	if eth0.RxBytes != 12345 {
		t.Errorf("RxBytes = %d; want 12345", eth0.RxBytes)
	}
	if eth0.RxPackets != 100 {
		t.Errorf("RxPackets = %d; want 100", eth0.RxPackets)
	}
	if eth0.RxErrors != 1 {
		t.Errorf("RxErrors = %d; want 1", eth0.RxErrors)
	}
	// Tx columns start at field index 8: bytes(8) packets(9) errs(10)
	if eth0.TxBytes != 67890 {
		t.Errorf("TxBytes = %d; want 67890", eth0.TxBytes)
	}
	if eth0.TxPackets != 200 {
		t.Errorf("TxPackets = %d; want 200", eth0.TxPackets)
	}
	if eth0.TxErrors != 2 {
		t.Errorf("TxErrors = %d; want 2", eth0.TxErrors)
	}
}

func TestParseProcNetDev_skipsHeaderLines(t *testing.T) {
	// The first two lines of /proc/net/dev are column headers and must
	// never appear as interfaces. Regression guard: if someone "fixes"
	// the header-skip to count lines from 0, this catches it.
	ifaces := parseProcNetDev([]byte(sampleProcNetDev))
	if _, ok := ifaces["Inter-|   Receive"]; ok {
		t.Error("header line 1 decoded as interface")
	}
	if _, ok := ifaces["face |bytes"]; ok {
		t.Error("header line 2 decoded as interface")
	}
}

func TestParseProcNetDev_malformedShortLinesSkipped(t *testing.T) {
	// A line with too few fields (kernel corruption, truncated read)
	// must be silently skipped, not produce a zero-counter entry.
	malformed := `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 1 2 3
`
	ifaces := parseProcNetDev([]byte(malformed))
	if _, ok := ifaces["eth0"]; ok {
		t.Error("malformed eth0 line should have been skipped")
	}
}

func TestParseProcNetDev_empty(t *testing.T) {
	ifaces := parseProcNetDev([]byte(""))
	if len(ifaces) != 0 {
		t.Errorf("empty input produced %d interfaces", len(ifaces))
	}
}
