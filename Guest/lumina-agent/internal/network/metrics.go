package network

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// metricsInterval is the ticker cadence for periodic snapshots. 2s
// matches heartbeat rate — already acceptable wire chatter, gives
// consumers sub-second-ish granularity without flooding vsock.
const metricsInterval = 2 * time.Second

// metricsFirstSampleDelay is the initial wait before the first
// snapshot. Short runs (≤1s) still capture one sample; we don't race
// configure_network (counters start at zero and are safe to read).
const metricsFirstSampleDelay = 500 * time.Millisecond

// Test injection — production always reads the real procfs file.
var readProcNetDev = defaultReadProcNetDev

// StartMetricsTicker runs in its own goroutine, emitting
// NetworkMetricsMsg on the wire every metricsInterval until ctx is
// cancelled. Non-ethernet interfaces (lo) are excluded — consumers
// care about externally-visible traffic. On read error, the ticker
// skips the sample and tries again next cycle rather than tearing
// itself down.
func StartMetricsTicker(ctx context.Context, w *wire.Writer) {
	// Initial delay so the first sample lands before a 1s run exits,
	// but after enough boot noise settles that counters aren't zero.
	select {
	case <-ctx.Done():
		return
	case <-time.After(metricsFirstSampleDelay):
	}
	sendSample(w)

	ticker := time.NewTicker(metricsInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sendSample(w)
		}
	}
}

func sendSample(w *wire.Writer) {
	data, err := readProcNetDev()
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "metrics: read /proc/net/dev: %v\n", err)
		return
	}
	interfaces := parseProcNetDev(data)
	if len(interfaces) == 0 {
		return
	}
	_ = w.Send(protocol.NetworkMetricsMsg{
		Type:       protocol.TypeNetworkMetrics,
		Interfaces: interfaces,
	})
}

func defaultReadProcNetDev() ([]byte, error) {
	return os.ReadFile("/proc/net/dev")
}

// parseProcNetDev parses the kernel's /proc/net/dev format. The file
// has two header lines, then one line per interface in the shape:
//
//	  iface: rxBytes rxPackets rxErrs rxDrop rxFifo rxFrame rxCompressed rxMulticast  txBytes txPackets txErrs txDrop txFifo txColls txCarrier txCompressed
//
// Loopback ("lo") is excluded — it's not useful observability for a
// disposable VM, and surfaces no real network behaviour.
func parseProcNetDev(data []byte) map[string]protocol.InterfaceCounters {
	out := map[string]protocol.InterfaceCounters{}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	lineNum := 0
	for scanner.Scan() {
		lineNum++
		if lineNum <= 2 {
			continue // two header lines
		}
		line := scanner.Text()
		colonIdx := bytes.IndexByte([]byte(line), ':')
		if colonIdx < 0 {
			continue
		}
		iface := string(bytes.TrimSpace([]byte(line[:colonIdx])))
		if iface == "" || iface == "lo" {
			continue
		}
		fields := bytes.Fields([]byte(line[colonIdx+1:]))
		if len(fields) < 16 {
			continue
		}
		counters := protocol.InterfaceCounters{
			RxBytes:   parseUint64(fields[0]),
			RxPackets: parseUint64(fields[1]),
			RxErrors:  parseUint64(fields[2]),
			TxBytes:   parseUint64(fields[8]),
			TxPackets: parseUint64(fields[9]),
			TxErrors:  parseUint64(fields[10]),
		}
		out[iface] = counters
	}
	return out
}

func parseUint64(b []byte) uint64 {
	n, err := strconv.ParseUint(string(b), 10, 64)
	if err != nil {
		return 0
	}
	return n
}
