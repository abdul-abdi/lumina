// Package transfer handles host↔guest file copy. Uploads stream
// base64 NDJSON chunks from the host; downloads stream them back.
package transfer

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/protocol"
	"github.com/abdullahiabdi/lumina/guest/lumina-agent/internal/wire"
)

// DownloadChunkSize is the raw-byte chunk size for downloads. 45 KiB
// base64-encodes to ~60 KiB, comfortably under the 64 KiB frame cap.
const DownloadChunkSize = 45 * 1024

// HandleUpload writes a file using the first UploadMsg and any
// subsequent UploadMsg frames read from scanner until Eof=true.
func HandleUpload(w *wire.Writer, scanner *bufio.Scanner, first protocol.UploadMsg) {
	// Ensure parent directory exists.
	if err := os.MkdirAll(filepath.Dir(first.Path), 0o755); err != nil {
		sendUploadError(w, first.Path, err)
		return
	}

	f, err := os.Create(first.Path)
	if err != nil {
		sendUploadError(w, first.Path, err)
		return
	}
	defer f.Close()

	// First chunk.
	if err := writeChunk(f, first.Data); err != nil {
		sendUploadError(w, first.Path, err)
		return
	}
	_ = w.Send(protocol.UploadAckMsg{Type: protocol.TypeUploadAck, Seq: first.Seq})

	// Remaining chunks if any.
	if !first.Eof {
		for scanner.Scan() {
			var msg protocol.UploadMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				sendUploadError(w, first.Path, err)
				return
			}
			// Skip interleaved heartbeat or unrelated frames.
			if msg.Type != protocol.TypeUpload {
				continue
			}
			if err := writeChunk(f, msg.Data); err != nil {
				sendUploadError(w, first.Path, err)
				return
			}
			_ = w.Send(protocol.UploadAckMsg{Type: protocol.TypeUploadAck, Seq: msg.Seq})
			if msg.Eof {
				break
			}
		}
	}

	// Optional mode (octal string).
	if first.Mode != "" {
		if mode, perr := strconv.ParseUint(first.Mode, 8, 32); perr == nil {
			_ = os.Chmod(first.Path, os.FileMode(mode))
		}
	}

	_ = w.Send(protocol.UploadDoneMsg{Type: protocol.TypeUploadDone, Path: first.Path})
}

// HandleDownload streams a file back to the host as base64 chunks,
// terminated by an Eof=true frame.
func HandleDownload(w *wire.Writer, req protocol.DownloadReqMsg) {
	f, err := os.Open(req.Path)
	if err != nil {
		_ = w.Send(protocol.DownloadErrorMsg{
			Type:  protocol.TypeDownloadError,
			Path:  req.Path,
			Error: err.Error(),
		})
		return
	}
	defer f.Close()

	buf := make([]byte, DownloadChunkSize)
	seq := 0
	sentEOF := false

	for {
		n, readErr := f.Read(buf)
		if n > 0 {
			eof := readErr == io.EOF
			_ = w.Send(protocol.DownloadDataMsg{
				Type: protocol.TypeDownloadData,
				Path: req.Path,
				Data: base64.StdEncoding.EncodeToString(buf[:n]),
				Seq:  seq,
				Eof:  eof,
			})
			seq++
			if eof {
				sentEOF = true
			}
		}
		if readErr != nil {
			if readErr == io.EOF {
				if !sentEOF {
					_ = w.Send(protocol.DownloadDataMsg{
						Type: protocol.TypeDownloadData,
						Path: req.Path,
						Data: "",
						Seq:  seq,
						Eof:  true,
					})
				}
				return
			}
			_ = w.Send(protocol.DownloadErrorMsg{
				Type:  protocol.TypeDownloadError,
				Path:  req.Path,
				Error: readErr.Error(),
			})
			return
		}
	}
}

func writeChunk(f *os.File, b64 string) error {
	chunk, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return fmt.Errorf("base64 decode: %w", err)
	}
	_, err = f.Write(chunk)
	return err
}

func sendUploadError(w *wire.Writer, path string, err error) {
	_ = w.Send(protocol.UploadErrorMsg{
		Type:  protocol.TypeUploadError,
		Path:  path,
		Error: err.Error(),
	})
}
