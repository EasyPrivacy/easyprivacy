package drive

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"os"
	"time"
)

// A connection carries one authorized operation. Content is streamed outside
// metadata frames; accepting an upload does not publish its partial bytes.
func ServeConnection(conn net.Conn, s *Store, verify *Verifier) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(20 * time.Second))
	fail := func(err error) {
		message := err.Error()
		var pathError *os.PathError
		if errors.As(err, &pathError) {
			message = "The server could not access that cloud item."
		}
		_ = WriteFrame(conn, map[string]any{"status": "error", "error": message})
	}
	var auth Authorization
	if err := ReadFrame(conn, &auth, 8192); err != nil {
		fail(errors.New("invalid Drive request"))
		return
	}
	if err := verify.Verify(auth); err != nil {
		fail(err)
		return
	}
	conn.SetDeadline(time.Now().Add(10 * time.Minute))
	c := auth.Command
	switch c.Op {
	case "volumes":
		_ = WriteFrame(conn, map[string]any{"status": "ok", "volumes": s.Volumes()})
	case "list":
		entries, next, err := s.List(c)
		if err != nil {
			fail(err)
			return
		}
		_ = WriteFrame(conn, map[string]any{"status": "ok", "entries": entries, "next": next})
	case "mkdir", "move", "delete":
		if err := s.Change(c); err != nil {
			fail(err)
			return
		}
		_ = WriteFrame(conn, map[string]string{"status": "ok"})
	case "upload":
		upload, err := s.Begin(c)
		if err != nil {
			fail(err)
			return
		}
		defer upload.Abort()
		if err = WriteFrame(conn, map[string]string{"status": "ready"}); err != nil {
			return
		}
		if err = upload.ReceiveChecked(conn, func() error {
			key, err := verify.Lookup(auth.Device)
			if err != nil {
				return errors.New("could not recheck device authorization with Core; the upload was not saved")
			}
			if !bytes.Equal(key, auth.Identity) {
				return errors.New("device authorization changed before the upload finished")
			}
			return nil
		}); err != nil {
			fail(err)
			return
		}
		_ = WriteFrame(conn, map[string]string{"status": "ok", "sha256": c.SHA256})
	case "download":
		file, entry, err := s.Download(c)
		if err != nil {
			fail(err)
			return
		}
		defer file.Close()
		if err = WriteFrame(conn, map[string]any{"status": "ok", "entry": entry}); err != nil {
			return
		}
		h := sha256.New()
		if _, err = io.CopyN(io.MultiWriter(conn, h), file, entry.Size); err != nil {
			return
		}
		_ = WriteFrame(conn, map[string]string{"status": "ok", "sha256": hex.EncodeToString(h.Sum(nil))})
	}
}
