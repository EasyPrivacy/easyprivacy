package node

import (
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Access is restricted by a mode-0700 parent and mode-0600 Unix socket. Only
// root and the dedicated service identity can use this local administration API.
func (s *Server) serveAdmin(path string) (func(), error) {
	dir := filepath.Dir(path)
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		return nil, errors.New("admin socket directory must exist with mode 0700")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, errors.New("refusing to replace a non-socket admin path")
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0600); err != nil {
		l.Close()
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /pairing-code", func(w http.ResponseWriter, r *http.Request) {
		code, err := s.CreatePairingCode()
		if err != nil {
			writeError(w, 429, err.Error())
			return
		}
		writeJSON(w, 200, code)
	})
	mux.HandleFunc("GET /devices", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"devices": s.devices.List()})
	})
	mux.HandleFunc("POST /devices/{id}/revoke", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		if err := s.revokeLocked(r.PathValue("id")); err != nil {
			if s.revocationCommitted(r.PathValue("id")) {
				writeJSON(w, 200, map[string]string{"status": "revoked", "warning": err.Error()})
				return
			}
			writeError(w, 400, "Could not revoke that device.")
			return
		}
		writeJSON(w, 200, map[string]string{"status": "revoked"})
	})
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	}), ReadHeaderTimeout: time.Second, ReadTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second, IdleTimeout: time.Second, MaxHeaderBytes: 4096}
	go func() { _ = server.Serve(l) }()
	return func() { _ = server.Close(); _ = os.Remove(path) }, nil
}
