package node

import (
	"context"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"io"
	"mime"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const SessionLifetime = time.Hour

type session struct {
	Expires  time.Time
	DeviceID string
}
type attempts struct {
	Since time.Time
	Count int
}
type Server struct {
	state         *State
	version       string
	started       time.Time
	mu            sync.Mutex
	sessions      map[[32]byte]session
	attempts      map[string]attempts
	global        attempts
	passwordSlots chan struct{}
	devices       *DeviceStore
	code          *pairingCode
	lastCode      time.Time
	pairings      map[string]*pairingExchange
	enrollments   map[string]*pendingEnrollment
	challenges    map[string]deviceChallenge
	vpn           vpn.Control
}

func NewServer(state *State, version string) *Server {
	devices, _ := OpenDeviceStore("")
	return &Server{state: state, version: version, started: time.Now(), sessions: make(map[[32]byte]session), attempts: make(map[string]attempts), passwordSlots: make(chan struct{}, 2), devices: devices, pairings: make(map[string]*pairingExchange), enrollments: make(map[string]*pendingEnrollment), challenges: make(map[string]deviceChallenge)}
}

func (s *Server) UseDeviceStore(store *DeviceStore) { s.devices = store }

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "alive"}) })
	mux.HandleFunc("POST /api/v1/login", s.login)
	mux.HandleFunc("GET /api/v1/status", s.status)
	mux.HandleFunc("POST /api/v1/logout", s.logout)
	mux.HandleFunc("POST /api/v1/pairing/start", s.pairingStart)
	mux.HandleFunc("POST /api/v1/pairing/finish", s.pairingFinish)
	mux.HandleFunc("POST /api/v1/pairing/enroll", s.pairingEnroll)
	mux.HandleFunc("POST /api/v1/pairing/code", s.createPairingCode)
	mux.HandleFunc("POST /api/v1/device/challenge", s.deviceChallenge)
	mux.HandleFunc("POST /api/v1/device/login", s.deviceLogin)
	mux.HandleFunc("GET /api/v1/devices", s.listDevices)
	mux.HandleFunc("POST /api/v1/devices/{id}/revoke", s.revokeDevice)
	mux.HandleFunc("GET /api/v1/vpn/exits", s.vpnExits)
	mux.HandleFunc("POST /api/v1/vpn/peer", s.vpnPeer)
	mux.HandleFunc("POST /api/v1/vpn/service", s.vpnService)
	mux.HandleFunc("POST /api/v1/vpn/disconnect", s.vpnDisconnect)
	mux.HandleFunc("GET /api/v1/vpn/status", s.vpnStatus)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.TLS == nil {
			writeError(w, 400, "An encrypted connection is required.")
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func writeError(w http.ResponseWriter, code int, text string) {
	writeJSON(w, code, map[string]string{"error": text})
}

func (s *Server) allowLogin(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	for ip, entry := range s.attempts {
		if now.Sub(entry.Since) >= time.Minute {
			delete(s.attempts, ip)
		}
	}
	if now.Sub(s.global.Since) >= time.Minute {
		s.global = attempts{Since: now}
	}
	entry, exists := s.attempts[host]
	if s.global.Count >= 60 || (!exists && len(s.attempts) >= 1024) || entry.Count >= 10 {
		return false
	}
	if !exists {
		entry.Since = now
	}
	entry.Count++
	s.attempts[host] = entry
	s.global.Count++
	return true
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if !s.allowLogin(r.RemoteAddr) {
		w.Header().Set("Retry-After", "60")
		writeError(w, 429, "Too many sign-in attempts. Try again shortly.")
		return
	}
	mediaType, _, mediaErr := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaErr != nil || mediaType != "application/json" {
		writeError(w, 415, "Send a JSON sign-in request.")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var input struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil {
		writeError(w, 400, "Invalid sign-in request.")
		return
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF || len(input.Username) > 64 || len(input.Password) > 1024 {
		writeError(w, 400, "Invalid sign-in request.")
		return
	}
	select {
	case s.passwordSlots <- struct{}{}:
		defer func() { <-s.passwordSlots }()
	default:
		w.Header().Set("Retry-After", "2")
		writeError(w, 429, "Sign-in is busy. Try again shortly.")
		return
	}
	valid, err := s.passwordMatches(input.Username, input.Password)
	if err != nil {
		writeError(w, 500, "Sign-in is temporarily unavailable.")
		return
	}
	if !valid {
		writeError(w, 401, "Incorrect username or password.")
		return
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		writeError(w, 500, "Sign-in is temporarily unavailable.")
		return
	}
	token := hex.EncodeToString(raw)
	expiry := time.Now().UTC().Add(SessionLifetime)
	s.mu.Lock()
	for key, entry := range s.sessions {
		if !time.Now().Before(entry.Expires) {
			delete(s.sessions, key)
		}
	}
	if len(s.sessions) >= 64 {
		s.mu.Unlock()
		writeError(w, 429, "Too many active sessions. Disconnect an existing client or wait for expiry.")
		return
	}
	s.sessions[sha256.Sum256([]byte(token))] = session{Expires: expiry}
	s.mu.Unlock()
	writeJSON(w, 200, map[string]any{"access_token": token, "expires_at": expiry})
}

func (s *Server) passwordMatches(username, password string) (bool, error) {
	candidate, err := pbkdf2.Key(sha256.New, password, s.state.Salt, PasswordIterations, 32)
	if err != nil {
		return false, err
	}
	defer clear(candidate)
	actual, wanted := sha256.Sum256([]byte(username)), sha256.Sum256([]byte(s.state.Username))
	return subtle.ConstantTimeCompare(candidate, s.state.PasswordHash)&subtle.ConstantTimeCompare(actual[:], wanted[:]) == 1, nil
}

func (s *Server) authenticate(r *http.Request) (session, bool) {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") || len(value) != 7+64 {
		return session{}, false
	}
	key := sha256.Sum256([]byte(strings.TrimPrefix(value, "Bearer ")))
	s.mu.Lock()
	defer s.mu.Unlock()
	valueSession, ok := s.sessions[key]
	if ok && !time.Now().Before(valueSession.Expires) {
		delete(s.sessions, key)
		return session{}, false
	}
	if ok && valueSession.DeviceID != "" {
		if _, active := s.devices.Active(valueSession.DeviceID); !active {
			delete(s.sessions, key)
			return session{}, false
		}
	}
	return valueSession, ok
}

func (s *Server) authenticateDevice(r *http.Request) (session, bool) {
	value, ok := s.authenticate(r)
	return value, ok && value.DeviceID != ""
}
func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	session, ok := s.authenticate(r)
	if !ok {
		writeError(w, 401, "Sign in to the core again.")
		return
	}
	writeJSON(w, 200, map[string]any{"core_name": s.state.Name, "version": s.version, "uptime_seconds": int64(time.Since(s.started).Seconds()), "server_time": time.Now().UTC(), "session_expires_at": session.Expires, "device_id": session.DeviceID})
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authenticate(r); !ok {
		writeError(w, 401, "Sign in to the core again.")
		return
	}
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	s.mu.Lock()
	delete(s.sessions, sha256.Sum256([]byte(token)))
	s.mu.Unlock()
	writeJSON(w, 200, map[string]string{"status": "signed_out"})
}

func (s *Server) Serve(ctx context.Context) error { return s.ServeWithAdmin(ctx, "") }

func (s *Server) ServeWithAdmin(ctx context.Context, adminSocket string) error {
	cert, err := s.state.Certificate()
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", s.state.Listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	if adminSocket != "" {
		stop, err := s.serveAdmin(adminSocket)
		if err != nil {
			return err
		}
		defer stop()
	}
	defer func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.clearPairingsLocked()
	}()
	server := &http.Server{Handler: s.Handler(), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}}}
	done := make(chan error, 1)
	go func() { done <- server.ServeTLS(listener, "", "") }()
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
		stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(stop); err != nil {
			_ = server.Close()
			return err
		}
		return nil
	}
}
