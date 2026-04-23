// Package bootmark writes boot-profile phase markers to /dev/kmsg and
// stderr. The host parses these from the serial-console buffer to
// build a BootProfile. Safe to call before vsock is up.
package bootmark

import (
	"bytes"
	"fmt"
	"os"
)

// Mark emits a `LUMINA_BOOT phase=<phase> t=<uptime_seconds>` line to
// both the kernel log (via /dev/kmsg) and stderr. Any write error is
// swallowed — bootmarks are diagnostics, never control flow.
func Mark(phase string) {
	t := readUptime()
	line := fmt.Sprintf("LUMINA_BOOT phase=%s t=%s\n", phase, t)

	if f, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0); err == nil {
		_, _ = f.WriteString(line)
		_ = f.Close()
	}
	// stderr is routed to the serial console on VZ setups.
	_, _ = fmt.Fprint(os.Stderr, line)
}

func readUptime() string {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return "0"
	}
	// /proc/uptime is "<active> <idle>"; take just the active seconds.
	if i := bytes.IndexByte(data, ' '); i > 0 {
		return string(data[:i])
	}
	return string(data)
}
