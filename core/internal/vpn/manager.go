package vpn

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Backend interface {
	Up(Config) error
	SetPeer(Config, Peer) error
	RemovePeer(string) error
	PeerStatus(string) (Status, error)
	Down() error
}
type Manager struct {
	mu         sync.Mutex
	config     Config
	path       string
	peers      map[string]Peer
	backend    Backend
	authorized func() (map[string]bool, error)
}

func NewManager(c Config, dir string, b Backend, auth func() (map[string]bool, error)) (*Manager, error) {
	if e := c.Validate(); e != nil {
		return nil, e
	}
	m := &Manager{config: c, path: filepath.Join(dir, "peers.json"), peers: map[string]Peer{}, backend: b, authorized: auth}
	var peers []Peer
	if e := ReadPrivate(m.path, &peers); e != nil && !errors.Is(e, os.ErrNotExist) {
		return nil, e
	}
	if len(peers) > 128 {
		return nil, errors.New("too many VPN peers")
	}
	hosts := map[int]bool{}
	keys := map[string]bool{}
	services := 0
	for _, p := range peers {
		if !ValidID(p.DeviceID) || p.Host < 2 || p.Host > 254 || hosts[p.Host] || keys[p.PublicKey] {
			return nil, errors.New("invalid persisted VPN peer")
		}
		if _, e := Key(p.PublicKey); e != nil {
			return nil, e
		}
		if p.Service {
			services++
		}
		if _, err := ManagementRoutes(p.Management); err != nil {
			return nil, err
		}
		if !p.Service && p.Management != "" {
			return nil, errors.New("only a service may advertise management routes")
		}
		if services > 1 || (p.ExitID != "" && p.ExitID != "vps" && p.ExitID != "home") || (p.Service && (p.ExitID != "" || !validServiceName(p.Name))) {
			return nil, errors.New("invalid persisted service or exit")
		}
		if _, exists := m.peers[p.DeviceID]; exists {
			return nil, errors.New("duplicate VPN device")
		}
		m.peers[p.DeviceID] = p
		hosts[p.Host] = true
		keys[p.PublicKey] = true
	}
	return m, nil
}
func (m *Manager) save() error {
	ps := make([]Peer, 0, len(m.peers))
	for _, p := range m.peers {
		ps = append(ps, p)
	}
	return SavePrivate(m.path, ps)
}
func (m *Manager) reconcile() error {
	authorized, e := m.authorized()
	if e != nil {
		for _, p := range m.peers {
			if removeErr := m.backend.RemovePeer(p.PublicKey); removeErr != nil {
				return removeErr
			}
		}
		return errors.New("device authorization records unavailable; VPN peers disabled")
	}
	changed := false
	for id, p := range m.peers {
		if !authorized[id] {
			if e := m.backend.RemovePeer(p.PublicKey); e != nil {
				return e
			}
			delete(m.peers, id)
			changed = true
		}
	}
	if changed {
		return m.save()
	}
	return nil
}
func (m *Manager) Register(id, key string) (Profile, error) {
	return m.RegisterExit(id, key, "vps")
}
func (m *Manager) RegisterExit(id, key, exit string) (Profile, error) {
	if exit == "" {
		exit = "vps"
	}
	if exit != "vps" && exit != "home" {
		return Profile{}, errors.New("unknown VPN exit")
	}
	return m.register(Peer{DeviceID: id, PublicKey: key, ExitID: exit})
}
func validServiceName(name string) bool {
	if len(name) == 0 || len(name) > 80 {
		return false
	}
	for _, r := range name {
		if r < 32 || r == 127 {
			return false
		}
	}
	return true
}
func (m *Manager) RegisterService(id, key, name string, addresses ...string) (ServiceProfile, error) {
	if !validServiceName(name) {
		return ServiceProfile{}, errors.New("enter a service name from 1 to 80 characters")
	}
	management := ""
	if len(addresses) > 0 {
		management = addresses[0]
	}
	if _, err := ManagementRoutes(management); err != nil {
		return ServiceProfile{}, err
	}
	p, err := m.register(Peer{DeviceID: id, PublicKey: key, Service: true, Name: name, Management: management})
	p.ExitID, p.ExitName = "home", name
	p.AllowedIPs = []string{m.config.Subnet}
	return ServiceProfile{Profile: p, Subnet: m.config.Subnet}, err
}
func (m *Manager) register(request Peer) (Profile, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, key := request.DeviceID, request.PublicKey
	var empty Profile
	if !ValidID(id) {
		return empty, errors.New("invalid device identity")
	}
	if _, e := Key(key); e != nil {
		return empty, e
	}
	allowed, e := m.authorized()
	if e != nil || !allowed[id] {
		return empty, errors.New("device is not authorized")
	}
	if e = m.reconcile(); e != nil {
		return empty, e
	}
	old, exists := m.peers[id]
	if exists && old.Service != request.Service {
		return empty, errors.New("disconnect this identity before changing its VPN role")
	}
	foundService := false
	for other, p := range m.peers {
		if p.Service {
			foundService = true
		}
		if request.Service && p.Service && other != id {
			return empty, errors.New("a home service node is already registered; revoke it before replacing it")
		}
		if other != id && p.PublicKey == key {
			return empty, errors.New("VPN key belongs to another device")
		}
	}
	if request.ExitID == "home" && !foundService {
		return empty, errors.New("configure the home service node first")
	}
	p := request
	p.Host = old.Host
	if !exists {
		if len(m.peers) >= 128 {
			return empty, errors.New("VPN peer limit reached")
		}
		used := map[int]bool{}
		for _, p := range m.peers {
			used[p.Host] = true
		}
		for host := 2; host <= 254; host++ {
			if !used[host] {
				p.Host = host
				break
			}
		}
	}
	if exists && old.PublicKey != key {
		if e = m.backend.RemovePeer(old.PublicKey); e != nil {
			return empty, e
		}
	}
	m.peers[id] = p
	if e = m.save(); e != nil {
		if exists {
			m.peers[id] = old
			_ = m.backend.SetPeer(m.config, old)
		} else {
			delete(m.peers, id)
		}
		return empty, e
	}
	if e = m.backend.SetPeer(m.config, p); e != nil {
		_ = m.backend.RemovePeer(key)
		if exists {
			m.peers[id] = old
			_ = m.backend.SetPeer(m.config, old)
		} else {
			delete(m.peers, id)
		}
		_ = m.save()
		return empty, e
	}
	profile := m.config.Profile(p)
	if p.ExitID == "home" {
		profile.ExitID = "home"
		for _, service := range m.peers {
			if service.Service {
				profile.ExitName = service.Name
				profile.ManagementRoutes, _ = ManagementRoutes(service.Management)
			}
		}
	}
	return profile, nil
}
func (m *Manager) Remove(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	p, exists := m.peers[id]
	if !exists {
		return nil
	}
	if e := m.backend.RemovePeer(p.PublicKey); e != nil {
		return e
	}
	delete(m.peers, id)
	return m.save()
}
func (m *Manager) Status(id string) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if e := m.reconcile(); e != nil {
		return Status{}, e
	}
	p, ok := m.peers[id]
	if !ok {
		return Status{}, nil
	}
	return m.backend.PeerStatus(p.PublicKey)
}
func (m *Manager) Info() (Exit, error) { return Exit{ID: "vps", Name: m.config.Name, Ready: true}, nil }
func (m *Manager) Exits() ([]Exit, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if e := m.reconcile(); e != nil {
		return nil, e
	}
	result := []Exit{{ID: "vps", Name: m.config.Name, Ready: true}}
	for _, p := range m.peers {
		if !p.Service {
			continue
		}
		status, e := m.backend.PeerStatus(p.PublicKey)
		ready := e == nil && status.Active && status.LastHandshake > 0 && time.Now().Unix()-status.LastHandshake < 180
		exit := Exit{ID: "home", Name: p.Name, Ready: ready}
		if !ready {
			exit.Message = "Home service node is offline or waiting for its VPN handshake."
		}
		result = append(result, exit)
	}
	return result, nil
}
func (m *Manager) Handler() http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any, e error) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if e != nil {
			w.WriteHeader(409)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": e.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(v)
	}
	mux.HandleFunc("GET /exit", func(w http.ResponseWriter, r *http.Request) { v, e := m.Info(); reply(w, v, e) })
	mux.HandleFunc("GET /exits", func(w http.ResponseWriter, r *http.Request) { v, e := m.Exits(); reply(w, v, e) })
	register := func(service bool) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			r.Body = http.MaxBytesReader(w, r.Body, 1024)
			defer r.Body.Close()
			d := json.NewDecoder(r.Body)
			d.DisallowUnknownFields()
			var p Peer
			var extra any
			if d.Decode(&p) != nil || d.Decode(&extra) != io.EOF || p.Host != 0 || p.Service || (!service && (p.Name != "" || p.Management != "")) || (service && p.ExitID != "") {
				reply(w, nil, errors.New("invalid peer request"))
				return
			}
			if service {
				v, e := m.RegisterService(p.DeviceID, p.PublicKey, p.Name, p.Management)
				reply(w, v, e)
			} else {
				v, e := m.RegisterExit(p.DeviceID, p.PublicKey, p.ExitID)
				reply(w, v, e)
			}
		}
	}
	mux.HandleFunc("POST /peers", register(false))
	mux.HandleFunc("POST /service", register(true))
	mux.HandleFunc("DELETE /peers/{id}", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"removed": true}, m.Remove(r.PathValue("id")))
	})
	mux.HandleFunc("GET /peers/{id}", func(w http.ResponseWriter, r *http.Request) { v, e := m.Status(r.PathValue("id")); reply(w, v, e) })
	return mux
}
func (m *Manager) Serve(ctx context.Context, socket string, gid int) error {
	if e := m.backend.Up(m.config); e != nil {
		return e
	}
	defer m.backend.Down()
	m.mu.Lock()
	e := m.reconcile()
	if e == nil {
		for _, p := range m.peers {
			if e = m.backend.SetPeer(m.config, p); e != nil {
				break
			}
		}
	}
	m.mu.Unlock()
	if e != nil {
		return e
	}
	info, e := os.Lstat(socket)
	if e == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("refusing non-socket VPN path")
		}
		if e = os.Remove(socket); e != nil {
			return e
		}
	} else if !errors.Is(e, os.ErrNotExist) {
		return e
	}
	l, e := net.Listen("unix", socket)
	if e != nil {
		return e
	}
	defer l.Close()
	defer os.Remove(socket)
	if e = os.Chown(socket, 0, gid); e != nil {
		return e
	}
	if e = os.Chmod(socket, 0660); e != nil {
		return e
	}
	server := &http.Server{Handler: m.Handler(), ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 3 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 4096}
	done := make(chan error, 1)
	go func() { done <- server.Serve(l) }()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			return server.Shutdown(shutdown)
		case e := <-done:
			if errors.Is(e, http.ErrServerClosed) {
				return nil
			}
			return e
		case <-ticker.C:
			m.mu.Lock()
			e := m.reconcile()
			m.mu.Unlock()
			if e != nil {
				_ = server.Close()
				return fmt.Errorf("VPN authorization reconciliation failed: %w", e)
			}
		}
	}
}
