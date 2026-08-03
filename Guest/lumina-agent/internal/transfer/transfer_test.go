package transfer

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// recordingWriter wraps a net.Pipe so wire.Writer (which needs a real
// net.Conn) has somewhere to send to. Every decoded frame is pushed
// onto msgs in arrival order — receiving from that channel blocks
// until the frame has actually been parsed, so tests never race the
// background reader.
func recordingWriter(t *testing.T) (w *wire.Writer, msgs <-chan map[string]any) {
	t.Helper()
	hostConn, guestConn := net.Pipe()
	ch := make(chan map[string]any, 64)
	go func() {
		scanner := bufio.NewScanner(hostConn)
		for scanner.Scan() {
			var m map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &m); err == nil {
				ch <- m
			}
		}
		close(ch)
	}()
	t.Cleanup(func() {
		_ = guestConn.Close()
		_ = hostConn.Close()
	})
	return wire.NewWriter(guestConn), ch
}

func uploadFrame(path, data string, seq int, eof bool) []byte {
	b, _ := json.Marshal(protocol.UploadMsg{
		Type: protocol.TypeUpload, Path: path, Data: data, Seq: seq, Eof: eof,
	})
	return b
}

// TestHandleUpload_BuffersInterleavedFrames is the regression guard for
// the bug where a frame of any other type (exec, cancel, stdin,
// pty_input) arriving mid-upload was silently discarded by `continue`
// in the chunk loop — the host would then block on that command until
// its own timeout, having no idea the guest never saw it.
func TestHandleUpload_BuffersInterleavedFrames(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "out.bin")

	first := protocol.UploadMsg{
		Type: protocol.TypeUpload, Path: path,
		Data: base64.StdEncoding.EncodeToString([]byte("hello ")),
		Seq:  0, Eof: false,
	}

	execLine := []byte(`{"type":"exec","id":"abc-123","cmd":"echo hi","timeout":5,"env":{}}`)
	cancelLine := []byte(`{"type":"cancel","signal":15,"grace_period":5}`)
	lastChunk := uploadFrame(path, base64.StdEncoding.EncodeToString([]byte("world")), 1, true)

	lines := strings.Join([]string{string(execLine), string(cancelLine), string(lastChunk)}, "\n")
	scanner := bufio.NewScanner(strings.NewReader(lines + "\n"))

	w, msgs := recordingWriter(t)

	leftover := HandleUpload(w, scanner, first)

	if len(leftover) != 2 {
		t.Fatalf("expected 2 buffered frames, got %d: %v", len(leftover), leftover)
	}
	var got0, got1 map[string]any
	if err := json.Unmarshal(leftover[0], &got0); err != nil {
		t.Fatalf("leftover[0] not valid JSON: %v", err)
	}
	if got0["type"] != "exec" || got0["id"] != "abc-123" {
		t.Errorf("leftover[0] = %v, want exec/abc-123", got0)
	}
	if err := json.Unmarshal(leftover[1], &got1); err != nil {
		t.Fatalf("leftover[1] not valid JSON: %v", err)
	}
	if got1["type"] != "cancel" {
		t.Errorf("leftover[1] = %v, want cancel", got1)
	}

	// Wire traffic: ack seq0, ack seq1, done — in that order, with the
	// interleaved frames never surfacing as upload traffic.
	wantTypes := []string{"upload_ack", "upload_ack", "upload_done"}
	for i, want := range wantTypes {
		m := <-msgs
		if m["type"] != want {
			t.Errorf("frame %d: got type %v, want %v", i, m["type"], want)
		}
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading uploaded file: %v", err)
	}
	if string(content) != "hello world" {
		t.Errorf("uploaded content = %q, want %q", content, "hello world")
	}
}

// TestHandleUpload_NoInterleavedFrames_LeftoverEmpty locks the common
// case: a transfer with no interleaved traffic returns no leftover.
func TestHandleUpload_NoInterleavedFrames_LeftoverEmpty(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "out.bin")

	first := protocol.UploadMsg{
		Type: protocol.TypeUpload, Path: path,
		Data: base64.StdEncoding.EncodeToString([]byte("solo")),
		Seq:  0, Eof: true,
	}
	scanner := bufio.NewScanner(strings.NewReader(""))

	w, msgs := recordingWriter(t)
	leftover := HandleUpload(w, scanner, first)

	if len(leftover) != 0 {
		t.Fatalf("expected no leftover frames, got %d", len(leftover))
	}
	m := <-msgs
	if m["type"] != "upload_ack" {
		t.Errorf("got type %v, want upload_ack", m["type"])
	}
	m = <-msgs
	if m["type"] != "upload_done" {
		t.Errorf("got type %v, want upload_done", m["type"])
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading uploaded file: %v", err)
	}
	if string(content) != "solo" {
		t.Errorf("uploaded content = %q, want %q", content, "solo")
	}
}
