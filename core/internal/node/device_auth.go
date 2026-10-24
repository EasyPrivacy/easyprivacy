package node

import (
	"crypto/ed25519"
	"crypto/sha256"
	"fmt"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"net/http"
	"time"
)

type deviceChallenge struct {
	DeviceID string
	Expires  time.Time
}

func deviceLoginMessage(pin, id, challenge string) []byte {
	return []byte("easyprivacy.device-login.v1\n" + pin + "\n" + id + "\n" + challenge)
}

func (s *Server) deviceChallenge(w http.ResponseWriter, r *http.Request) {
	if !s.allowLogin(r.RemoteAddr) {
		writeError(w, 429, "Too many connection attempts. Try again shortly.")
		return
	}
	var input struct {
		ID string `json:"device_id"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	if !validHexID(input.ID) {
		writeError(w, 400, "Invalid device identity.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.devices.Active(input.ID); !ok {
		writeError(w, 401, "This device is not authorized. Pair it again using a new device identity.")
		return
	}
	now := time.Now()
	for id, c := range s.challenges {
		if !now.Before(c.Expires) {
			delete(s.challenges, id)
		}
	}
	if len(s.challenges) >= 64 {
		writeError(w, 429, "Device sign-in is busy. Try again shortly.")
		return
	}
	id := randomID()
	expires := now.Add(30 * time.Second)
	s.challenges[id] = deviceChallenge{DeviceID: input.ID, Expires: expires}
	writeJSON(w, 200, map[string]any{"challenge_id": id, "expires_at": expires})
}

func (s *Server) deviceLogin(w http.ResponseWriter, r *http.Request) {
	if !s.allowLogin(r.RemoteAddr) {
		writeError(w, 429, "Too many connection attempts. Try again shortly.")
		return
	}
	var input struct {
		ID        string `json:"device_id"`
		Challenge string `json:"challenge_id"`
		Signature []byte `json:"signature"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	challenge, ok := s.challenges[input.Challenge]
	delete(s.challenges, input.Challenge)
	d, active := s.devices.Active(input.ID)
	if !ok || !active || challenge.DeviceID != input.ID || !time.Now().Before(challenge.Expires) || len(input.Signature) != 64 || !ed25519.Verify(d.PublicKey, deviceLoginMessage(s.state.Fingerprint(), input.ID, input.Challenge), input.Signature) {
		writeError(w, 401, "Device authentication failed. Try reconnecting or pair a new device identity.")
		return
	}
	now := time.Now()
	for key, v := range s.sessions {
		if !now.Before(v.Expires) {
			delete(s.sessions, key)
		}
	}
	if len(s.sessions) >= 64 {
		writeError(w, 429, "Too many active sessions. Disconnect an existing client or wait for expiry.")
		return
	}
	token := randomID()
	expires := now.UTC().Add(SessionLifetime)
	s.sessions[sha256.Sum256([]byte(token))] = session{Expires: expires, DeviceID: input.ID}
	writeJSON(w, 200, map[string]any{"access_token": token, "expires_at": expires})
}

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	writeJSON(w, 200, map[string]any{"devices": s.devices.List(), "current_device_id": current.DeviceID})
}

func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, active := s.devices.Active(current.DeviceID); !active {
		writeError(w, 401, "Device authorization was revoked.")
		return
	}
	if err := s.revokeLocked(r.PathValue("id")); err != nil {
		if s.revocationCommitted(r.PathValue("id")) {
			writeJSON(w, 200, map[string]string{"status": "revoked", "warning": err.Error()})
			return
		}
		writeError(w, 400, "Could not revoke that device.")
		return
	}
	writeJSON(w, 200, map[string]string{"status": "revoked"})
}

func (s *Server) revocationCommitted(id string) bool {
	for _, d := range s.devices.List() {
		if d.ID == id {
			return d.Revoked
		}
	}
	return false
}

func (s *Server) revokeLocked(id string) error {
	if err := s.devices.Revoke(id); err != nil {
		return err
	}
	for key, v := range s.sessions {
		if v.DeviceID == id {
			delete(s.sessions, key)
		}
	}
	for key, v := range s.challenges {
		if v.DeviceID == id {
			delete(s.challenges, key)
		}
	}
	if s.code != nil && s.code.Creator == id {
		s.code = nil
		s.clearPairingsLocked()
	}
	if s.vpn != nil {
		remove := s.vpn.Remove
		if control, ok := s.vpn.(vpn.DeviceControl); ok {
			remove = control.RemoveDevice
		}
		if err := remove(id); err != nil {
			return fmt.Errorf("device revoked; VPN removal could not be confirmed: %w", err)
		}
	}
	return nil
}
