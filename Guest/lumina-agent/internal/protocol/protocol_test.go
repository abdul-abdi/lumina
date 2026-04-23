// Tests that the JSON struct tags on every wire type match their
// declared `Type` discriminator, so `encoding/json` round-trips
// without accidental key drift. The host parses by `type` and
// typed-field presence; a silent rename (`guest_port` → `guestPort`)
// would desync the guest and host with no compile error.
package protocol

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestTypeDiscriminators_AreStringConstants(t *testing.T) {
	// Exhaustive enumeration — any typo in protocol.go or a
	// discriminator drift between here and the host-side
	// `Protocol.swift` surfaces as a failing case.
	cases := map[string]string{
		TypeReady:            "ready",
		TypeHeartbeat:        "heartbeat",
		TypeExec:             "exec",
		TypeOutput:           "output",
		TypeExit:             "exit",
		TypeStdin:            "stdin",
		TypeStdinClose:       "stdin_close",
		TypeCancel:           "cancel",
		TypeConfigureNetwork: "configure_network",
		TypeNetworkReady:     "network_ready",
		TypeUpload:           "upload",
		TypeUploadAck:        "upload_ack",
		TypeUploadError:      "upload_error",
		TypeUploadDone:       "upload_done",
		TypeDownloadReq:      "download_req",
		TypeDownloadData:     "download_data",
		TypeDownloadError:    "download_error",
		TypePtyExec:          "pty_exec",
		TypePtyInput:         "pty_input",
		TypePtyOutput:        "pty_output",
		TypeWindowResize:     "window_resize",
		TypePortForwardStart: "port_forward_start",
		TypePortForwardStop:  "port_forward_stop",
		TypePortForwardReady: "port_forward_ready",
		TypePortForwardError: "port_forward_error",
	}
	for got, want := range cases {
		if got != want {
			t.Errorf("discriminator drift: got %q, want %q", got, want)
		}
	}
}

func TestExecRequest_Roundtrip(t *testing.T) {
	original := ExecRequest{
		Type:    TypeExec,
		ID:      "abc-123",
		Cmd:     "echo hi",
		Timeout: 30,
		Env:     map[string]string{"FOO": "bar"},
		Cwd:     "/tmp",
	}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded ExecRequest
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !reflect.DeepEqual(original, decoded) {
		t.Fatalf("roundtrip differs:\n  original: %+v\n   decoded: %+v",
			original, decoded)
	}
}

func TestExecRequest_CwdOmitsEmpty(t *testing.T) {
	// omitempty on Cwd keeps the wire minimal when the host doesn't
	// care about cwd. A regression here would send `"cwd":""` for
	// every exec, which is wasteful but not incorrect — this test
	// locks the existing behaviour so changes are deliberate.
	original := ExecRequest{
		Type: TypeExec, ID: "x", Cmd: "true", Timeout: 0,
		Env: map[string]string{},
	}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	asMap := map[string]any{}
	if err := json.Unmarshal(data, &asMap); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, present := asMap["cwd"]; present {
		t.Fatalf("expected cwd omitted on empty, got present in %v", asMap)
	}
}

func TestCancelMsg_OmitsEmptyID(t *testing.T) {
	// id is optional — nil means cancel-all. The host sends no id
	// field for broadcast cancel; we must not emit `"id":""`.
	msg := CancelMsg{Type: TypeCancel, Signal: 15, GracePeriod: 5}
	data, _ := json.Marshal(msg)
	asMap := map[string]any{}
	_ = json.Unmarshal(data, &asMap)
	if _, present := asMap["id"]; present {
		t.Fatalf("expected id omitted on empty, got present in %v", asMap)
	}
}

func TestPortForwardErrorMsg_HasExpectedShape(t *testing.T) {
	msg := PortForwardErrorMsg{
		Type: TypePortForwardError, GuestPort: 3000, Reason: "already active",
	}
	data, _ := json.Marshal(msg)
	asMap := map[string]any{}
	if err := json.Unmarshal(data, &asMap); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if asMap["type"] != "port_forward_error" {
		t.Fatalf("expected type=port_forward_error, got %v", asMap["type"])
	}
	if asMap["guest_port"] != float64(3000) {
		t.Fatalf("expected guest_port=3000, got %v", asMap["guest_port"])
	}
	if asMap["reason"] != "already active" {
		t.Fatalf("expected reason='already active', got %v", asMap["reason"])
	}
}

func TestPortForwardReadyMsg_HasExpectedShape(t *testing.T) {
	msg := PortForwardReadyMsg{
		Type: TypePortForwardReady, GuestPort: 3000, VsockPort: 1025,
	}
	data, _ := json.Marshal(msg)
	asMap := map[string]any{}
	_ = json.Unmarshal(data, &asMap)
	if asMap["type"] != "port_forward_ready" {
		t.Fatalf("expected type=port_forward_ready, got %v", asMap["type"])
	}
	if asMap["guest_port"] != float64(3000) {
		t.Fatalf("expected guest_port=3000, got %v", asMap["guest_port"])
	}
	if asMap["vsock_port"] != float64(1025) {
		t.Fatalf("expected vsock_port=1025, got %v", asMap["vsock_port"])
	}
}

func TestNewExit_BuildsCorrectDiscriminator(t *testing.T) {
	msg := NewExit("xyz", 42)
	if msg.Type != TypeExit {
		t.Errorf("expected type=exit, got %q", msg.Type)
	}
	if msg.ID != "xyz" {
		t.Errorf("expected id=xyz, got %q", msg.ID)
	}
	if msg.Code != 42 {
		t.Errorf("expected code=42, got %d", msg.Code)
	}
}

func TestOutputMsg_BinaryEncodingTag(t *testing.T) {
	// The binary streamer sets Encoding="base64"; text uses the
	// zero value which `omitempty` hides. Locking both to the
	// currently shipped wire shape.
	binary := OutputMsg{
		Type: TypeOutput, ID: "x", Stream: StreamStdout,
		Data: "QUJD", Encoding: "base64",
	}
	binData, _ := json.Marshal(binary)
	if !contains(binData, `"encoding":"base64"`) {
		t.Errorf("binary frame must carry encoding=base64, got %s", binData)
	}

	text := OutputMsg{
		Type: TypeOutput, ID: "x", Stream: StreamStdout,
		Data: "hello",
	}
	textData, _ := json.Marshal(text)
	if contains(textData, `"encoding"`) {
		t.Errorf("text frame must omit encoding, got %s", textData)
	}
}

func contains(b []byte, s string) bool {
	return indexOf(string(b), s) >= 0
}

// tiny substring search so the test file stays dep-free.
func indexOf(h, n string) int {
outer:
	for i := 0; i+len(n) <= len(h); i++ {
		for j := 0; j < len(n); j++ {
			if h[i+j] != n[j] {
				continue outer
			}
		}
		return i
	}
	return -1
}
