// Tests for the wire.Writer NDJSON framer. The Writer is shared by
// the dispatcher, heartbeat, and every per-command streamer on the
// guest — interleaved frames would break the host's NDJSON parser
// (one frame per line, no partial lines). These tests drive
// concurrent writers through a net.Pipe and assert each received
// line is a well-formed JSON object, i.e. no frame got cut in half.
package wire

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
)

func TestSend_SingleFrameWritesNDJSON(t *testing.T) {
	hostConn, guestConn := net.Pipe()
	defer hostConn.Close()
	defer guestConn.Close()

	w := NewWriter(guestConn)

	go func() {
		_ = w.Send(map[string]any{"type": "ready", "n": 1})
	}()

	scanner := bufio.NewScanner(hostConn)
	if !scanner.Scan() {
		t.Fatalf("expected one line, scanner error: %v", scanner.Err())
	}
	var got map[string]any
	if err := json.Unmarshal(scanner.Bytes(), &got); err != nil {
		t.Fatalf("decode failed: %v, raw=%q", err, scanner.Text())
	}
	if got["type"] != "ready" {
		t.Fatalf("expected type=ready, got %v", got["type"])
	}
}

func TestSend_ConcurrentWritersDoNotInterleaveFrames(t *testing.T) {
	// 8 writers * 500 frames each = 4000 frames through the same
	// net.Pipe. Every frame must arrive as a complete JSON object.
	// Before the internal mutex existed (or if it ever regresses),
	// concurrent Write calls would splice each other's bytes and the
	// NDJSON parser would choke on partial objects.
	hostConn, guestConn := net.Pipe()
	defer hostConn.Close()
	defer guestConn.Close()

	w := NewWriter(guestConn)

	const writers = 8
	const perWriter = 500
	const total = writers * perWriter

	// Tailing goroutine decodes NDJSON and reports any malformed line.
	done := make(chan error, 1)
	counts := make(map[int]int) // writer id → count
	var countsMu sync.Mutex

	go func() {
		scanner := bufio.NewScanner(hostConn)
		scanner.Buffer(make([]byte, 0, 65536), 1<<20)
		received := 0
		for scanner.Scan() {
			received++
			line := scanner.Bytes()
			var msg map[string]any
			if err := json.Unmarshal(line, &msg); err != nil {
				done <- fmt.Errorf(
					"malformed frame at n=%d: %v (raw=%q)",
					received, err, string(line),
				)
				return
			}
			id, _ := msg["writer"].(float64)
			countsMu.Lock()
			counts[int(id)]++
			countsMu.Unlock()
			if received == total {
				done <- nil
				return
			}
		}
		done <- fmt.Errorf("scanner ended early at n=%d: %v", received, scanner.Err())
	}()

	var wg sync.WaitGroup
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(writerID int) {
			defer wg.Done()
			for j := 0; j < perWriter; j++ {
				if err := w.Send(map[string]any{
					"type":   "tick",
					"writer": writerID,
					"seq":    j,
					// Padding to make frame boundaries obvious if they
					// ever get spliced — a spliced frame would be a
					// mix of padding + seq values.
					"pad": strings.Repeat("x", 32),
				}); err != nil {
					t.Errorf("Send failed: %v", err)
					return
				}
			}
		}(i)
	}

	wg.Wait()
	if err := <-done; err != nil {
		t.Fatalf("concurrent write test failed: %v", err)
	}

	countsMu.Lock()
	defer countsMu.Unlock()
	for i := 0; i < writers; i++ {
		if counts[i] != perWriter {
			t.Errorf("writer %d: expected %d frames, got %d",
				i, perWriter, counts[i])
		}
	}
}

func TestSend_MarshalErrorBubblesUp(t *testing.T) {
	hostConn, guestConn := net.Pipe()
	defer hostConn.Close()
	defer guestConn.Close()
	w := NewWriter(guestConn)

	// A channel can't be JSON-marshalled — Send should return the
	// marshal error without writing anything to the connection.
	err := w.Send(map[string]any{"ch": make(chan int)})
	if err == nil {
		t.Fatalf("expected marshal error, got nil")
	}
}
