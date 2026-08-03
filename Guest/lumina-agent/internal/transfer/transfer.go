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
// subsequent UploadMsg frames read from scanner until Eof=true. A
// frame of any other type that arrives interleaved (exec, cancel,
// stdin, pty_input, ...) is buffered rather than dropped and
// returned in leftover so the caller can replay it through normal
// dispatch once the transfer finishes — see internal/agent's
// handleUpload.
func HandleUpload(w *wire.Writer, scanner *bufio.Scanner, first protocol.UploadMsg) (leftover [][]byte) {
	// Ensure parent directory exists.
	if err := os.MkdirAll(filepath.Dir(first.Path), 0o755); err != nil {
		sendUploadError(w, first.Path, err)
		return leftover
	}

	f, err := os.Create(first.Path)
	if err != nil {
		sendUploadError(w, first.Path, err)
		return leftover
	}
	defer f.Close()

	// First chunk.
	if err := writeChunk(f, first.Data); err != nil {
		sendUploadError(w, first.Path, err)
		return leftover
	}
	_ = w.Send(protocol.UploadAckMsg{Type: protocol.TypeUploadAck, Seq: first.Seq})

	// Remaining chunks if any.
	sawEOF := first.Eof
	if !first.Eof {
		for scanner.Scan() {
			var msg protocol.UploadMsg
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				sendUploadError(w, first.Path, err)
				return leftover
			}
			if msg.Type != protocol.TypeUpload {
				// scanner.Bytes() aliases a buffer the next Scan()
				// call overwrites — copy before buffering.
				leftover = append(leftover, append([]byte(nil), scanner.Bytes()...))
				continue
			}
			if err := writeChunk(f, msg.Data); err != nil {
				sendUploadError(w, first.Path, err)
				return leftover
			}
			_ = w.Send(protocol.UploadAckMsg{Type: protocol.TypeUploadAck, Seq: msg.Seq})
			if msg.Eof {
				sawEOF = true
				break
			}
		}
	}

	// A scanner that ends without an Eof frame means the connection dropped
	// mid-transfer. Falling through to upload_done here left both sides
	// believing a truncated file was complete; remove it so nothing reads a
	// half-written path.
	if !sawEOF {
		_ = f.Close()
		_ = os.Remove(first.Path)
		err := scanner.Err()
		if err == nil {
			err = io.ErrUnexpectedEOF
		}
		sendUploadError(w, first.Path, err)
		return
	}

	// Optional mode (octal string). A file the caller cannot execute is a
	// failed upload, not a successful one — `lumina cp ./s.sh sid:/tmp/s.sh`
	// followed by `sh /tmp/s.sh` should not be where you find out.
	if first.Mode != "" {
		mode, perr := strconv.ParseUint(first.Mode, 8, 32)
		if perr != nil {
			sendUploadError(w, first.Path, fmt.Errorf("invalid mode %q: %w", first.Mode, perr))
			return
		}
		if cerr := os.Chmod(first.Path, os.FileMode(mode)); cerr != nil {
			sendUploadError(w, first.Path, fmt.Errorf("chmod %s: %w", first.Mode, cerr))
			return
		}
	}

	_ = w.Send(protocol.UploadDoneMsg{Type: protocol.TypeUploadDone, Path: first.Path})
	return leftover
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
