package clock

import (
	"os"
	"time"

	"golang.org/x/sys/unix"
)

func Sync() {
	f, err := os.Open("/dev/rtc0")
	if err != nil {
		return
	}
	defer f.Close()
	rtc, err := unix.IoctlGetRTCTime(int(f.Fd()))
	if err != nil {
		return
	}
	host := time.Date(int(rtc.Year)+1900, time.Month(rtc.Mon+1), int(rtc.Mday),
		int(rtc.Hour), int(rtc.Min), int(rtc.Sec), 0, time.UTC)
	if drift := time.Since(host); drift > -2*time.Second && drift < 2*time.Second {
		return
	}
	tv := unix.NsecToTimeval(host.UnixNano())
	_ = unix.Settimeofday(&tv)
}
