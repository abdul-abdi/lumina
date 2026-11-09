// Package wire handles NDJSON framing on top of a net.Conn. A single
// Writer is shared by every goroutine that sends to the host — the
// internal mutex serializes writes so the dispatcher, heartbeat, and
// per-command streamers never interleave a frame.
package wire

import (
	"encoding/json"
	"net"
	"sync"
)

type Writer struct {
	conn net.Conn
	mu   sync.Mutex
}

func NewWriter(conn net.Conn) *Writer {
	return &Writer{conn: conn}
}

func (w *Writer) Send(v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	w.mu.Lock()
	defer w.mu.Unlock()
	_, err = w.conn.Write(data)
	return err
}
