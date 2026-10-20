package node

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/easyprivacy/easyprivacy/core/internal/pake"
)

const PairingLifetime = 5 * time.Minute

type PairingCode struct {
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
}
type pairingCode struct {
	PairingCode
	Attempts   int
	Generation string
	Creator    string
}
type pairingExchange struct {
	PAKE             *pake.Exchange
	Context          [32]byte
	PublicKey        []byte
	Name, Generation string
	ExpiresAt        time.Time
}

type pendingEnrollment struct {
	PublicKey        []byte
	Name, Generation string
	ExpiresAt        time.Time
	ProofHash        [32]byte
	Attempts         int
}

func (s *Server) clearPairingsLocked() {
	for id, pending := range s.pairings {
		pending.PAKE.Close()
		delete(s.pairings, id)
	}
	clear(s.enrollments)
}

func randomID() string {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return hex.EncodeToString(raw)
}
func pairingContext(id, target, name string, publicKey []byte, pin string) [32]byte {
	return sha256.Sum256([]byte("easyprivacy.pairing.v2\n" + id + "\n" + target + "\n" + name + "\n" + base64.StdEncoding.EncodeToString(publicKey) + "\n" + pin))
}
func pairingMAC(key []byte, role string, context [32]byte, deviceID string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte("easyprivacy.pairing.v2." + role + "\n"))
	h.Write(context[:])
	h.Write([]byte("\n" + deviceID))
	return h.Sum(nil)
}

func readRequest(w http.ResponseWriter, r *http.Request, value any) bool {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		writeError(w, 415, "Send a JSON request.")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	var extra any
	if d.Decode(value) != nil || d.Decode(&extra) != io.EOF {
		writeError(w, 400, "Invalid request.")
		return false
	}
	return true
}

// All code and exchange state is protected by s.mu. Each begin consumes one
// guess, even if abandoned. A new code invalidates every previous exchange.
func (s *Server) newPairingCodeLocked(creator string) (PairingCode, error) {
	now := time.Now()
	if !s.lastCode.IsZero() && now.Sub(s.lastCode) < 10*time.Second {
		return PairingCode{}, errors.New("wait ten seconds before creating another pairing code")
	}
	if creator != "" {
		if _, ok := s.devices.Active(creator); !ok {
			return PairingCode{}, errors.New("device authorization was revoked")
		}
	}
	n, err := rand.Int(rand.Reader, big.NewInt(100000000))
	if err != nil {
		return PairingCode{}, err
	}
	s.clearPairingsLocked()
	code := PairingCode{Code: fmt.Sprintf("%08d", n.Int64()), ExpiresAt: now.UTC().Add(PairingLifetime)}
	s.code = &pairingCode{PairingCode: code, Generation: randomID(), Creator: creator}
	s.lastCode = now
	return code, nil
}

func (s *Server) CreatePairingCode() (PairingCode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.newPairingCodeLocked("")
}

func (s *Server) createPairingCode(w http.ResponseWriter, r *http.Request) {
	session, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	s.mu.Lock()
	code, err := s.newPairingCodeLocked(session.DeviceID)
	s.mu.Unlock()
	if err != nil {
		writeError(w, 429, err.Error())
		return
	}
	writeJSON(w, 200, code)
}

func (s *Server) pairingStart(w http.ResponseWriter, r *http.Request) {
	if !s.allowLogin(r.RemoteAddr) {
		writeError(w, 429, "Too many pairing attempts. Try again shortly.")
		return
	}
	var input struct {
		Target    string `json:"target"`
		Name      string `json:"device_name"`
		PublicKey []byte `json:"public_key"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	if len(input.PublicKey) != 32 || !validDeviceName(input.Name) || input.Target == "" || len(input.Target) > 255 || strings.ContainsAny(input.Target, "\r\n\x00") {
		writeError(w, 400, "Invalid device pairing request.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for id, p := range s.pairings {
		if !now.Before(p.ExpiresAt) {
			p.PAKE.Close()
			delete(s.pairings, id)
		}
	}
	for id, p := range s.enrollments {
		if !now.Before(p.ExpiresAt) {
			delete(s.enrollments, id)
		}
	}
	if s.code == nil || !now.Before(s.code.ExpiresAt) || s.code.Attempts >= 5 {
		writeError(w, 401, "Pairing is unavailable. Create a new code on the core or a paired device.")
		return
	}
	if s.code.Creator != "" {
		if _, ok := s.devices.Active(s.code.Creator); !ok {
			writeError(w, 401, "Create a new pairing code.")
			return
		}
	}
	s.code.Attempts++
	id := randomID()
	pin := s.state.Fingerprint()
	context := pairingContext(id, input.Target, input.Name, input.PublicKey, pin)
	exchange, err := pake.Start(1, s.code.Code, context)
	if err != nil {
		writeError(w, 500, "Pairing is temporarily unavailable.")
		return
	}
	expires := now.Add(30 * time.Second)
	if s.code.ExpiresAt.Before(expires) {
		expires = s.code.ExpiresAt
	}
	s.pairings[id] = &pairingExchange{PAKE: exchange, Context: context, PublicKey: input.PublicKey, Name: input.Name, Generation: s.code.Generation, ExpiresAt: expires}
	writeJSON(w, 200, map[string]any{"protocol": "easyprivacy.pairing.v2", "exchange_id": id, "message": exchange.Message, "core_fingerprint": pin})
}

func (s *Server) pairingFinish(w http.ResponseWriter, r *http.Request) {
	var input struct {
		ID      string `json:"exchange_id"`
		Message []byte `json:"message"`
		Proof   []byte `json:"proof"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.pairings[input.ID]
	if ok {
		delete(s.pairings, input.ID)
	}
	if !ok {
		writeError(w, 401, "Pairing failed. Create a new code and try again.")
		return
	}
	defer p.PAKE.Close()
	if s.code == nil || s.code.Generation != p.Generation || !time.Now().Before(s.code.ExpiresAt) || !time.Now().Before(p.ExpiresAt) {
		writeError(w, 401, "Pairing code or exchange expired.")
		return
	}
	if s.code.Creator != "" {
		if _, ok := s.devices.Active(s.code.Creator); !ok {
			writeError(w, 401, "Pairing authorization was revoked.")
			return
		}
	}
	key, err := p.PAKE.Finish(input.Message)
	if err != nil {
		writeError(w, 401, "Pairing failed. Check the code.")
		return
	}
	defer clear(key)
	id := deviceID(p.PublicKey)
	if len(input.Proof) != 32 || !hmac.Equal(input.Proof, pairingMAC(key, "app", p.Context, id)) {
		writeError(w, 401, "Pairing failed. Check the code.")
		return
	}
	// Code confirmation only verifies the core. It does not authorize a device.
	// The enrollment proof is derived independently and NEVER returned on this
	// provisional connection. The app sends it with the account credentials only
	// after establishing a new TLS connection pinned to the confirmed core.
	s.enrollments[input.ID] = &pendingEnrollment{PublicKey: p.PublicKey, Name: p.Name, Generation: p.Generation, ExpiresAt: s.code.ExpiresAt, ProofHash: sha256.Sum256(pairingMAC(key, "enroll", p.Context, id))}
	writeJSON(w, 200, map[string]any{"device_id": id, "proof": pairingMAC(key, "core", p.Context, id), "expires_at": s.code.ExpiresAt})
}

func (s *Server) enrollmentValidLocked(p *pendingEnrollment) bool {
	if p == nil || s.code == nil || p.Generation != s.code.Generation || !time.Now().Before(p.ExpiresAt) || !time.Now().Before(s.code.ExpiresAt) {
		return false
	}
	if s.code.Creator != "" {
		_, ok := s.devices.Active(s.code.Creator)
		return ok
	}
	return true
}

func (s *Server) pairingEnroll(w http.ResponseWriter, r *http.Request) {
	if !s.allowLogin(r.RemoteAddr) {
		writeError(w, 429, "Too many sign-in attempts. Try again shortly.")
		return
	}
	var input struct {
		ID       string `json:"exchange_id"`
		Proof    []byte `json:"proof"`
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	if len(input.Username) > 64 || len(input.Password) > 1024 {
		writeError(w, 400, "Invalid sign-in request.")
		return
	}
	proofHash := sha256.Sum256(input.Proof)
	s.mu.Lock()
	p := s.enrollments[input.ID]
	if !s.enrollmentValidLocked(p) || p.Attempts >= 5 || len(input.Proof) != 32 || !hmac.Equal(proofHash[:], p.ProofHash[:]) {
		s.mu.Unlock()
		writeError(w, 410, "Core verification expired or is invalid. Verify the core with a new code.")
		return
	}
	select {
	case s.passwordSlots <- struct{}{}:
	default:
		s.mu.Unlock()
		writeError(w, 429, "Sign-in is busy. Try again shortly.")
		return
	}
	p.Attempts++
	s.mu.Unlock()
	defer func() { <-s.passwordSlots }()
	valid, err := s.passwordMatches(input.Username, input.Password)
	if err != nil {
		writeError(w, 500, "Sign-in is temporarily unavailable.")
		return
	}
	if !valid {
		writeError(w, 401, "Incorrect username or password.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Recheck after password work: replacement, expiry, revocation or another
	// successful enrollment must invalidate even an already running request.
	if s.enrollments[input.ID] != p || !s.enrollmentValidLocked(p) {
		writeError(w, 410, "Core verification expired. Verify the core with a new code.")
		return
	}
	d, err := s.devices.Add(p.Name, p.PublicKey)
	if err != nil {
		writeError(w, 409, "Could not save this device. Check the core device records or create a fresh device identity.")
		return
	}
	s.code = nil
	s.clearPairingsLocked()
	writeJSON(w, 200, map[string]any{"device_id": d.ID})
}

func validHexID(id string) bool {
	b, err := hex.DecodeString(id)
	return err == nil && len(b) == 32 && id == strings.ToLower(id)
}
