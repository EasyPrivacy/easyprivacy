package vpn

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
)

const receiverLifetime = 120 * time.Second

type receiverLease struct {
	ID       string
	DeviceID string
	Expires  time.Time
}

// PrivateGrant permits one TCP receiver, never an arbitrary subnet or exit.
type PrivateGrant struct {
	Source, Destination string
	Port                int
}
type privateAccessBackend interface{ SetPrivateAccess([]PrivateGrant) error }

type PrivateServicesControl interface {
	PrivateTargets(string) ([]PrivateTarget, error)
	RegisterReceiver(string) (PrivateTarget, error)
	RemoveReceiver(string) error
}

func privateOnlyMessage(c Config) string {
	if c.PrivateOnly {
		return "Private connections are enabled. Internet exits are disabled."
	}
	return ""
}

func (m *Manager) probeTarget() PrivateTarget {
	return PrivateTarget{ID: "core.probe", Name: "Private connection check", Address: strings.TrimSuffix(m.config.Address(1), "/32"), Port: PrivateProbePort}
}

// Caller holds m.mu. Leases are intentionally transient and fail closed after
// helper restart; the Core runtime must renew them while Files is authorized.
func (m *Manager) syncPrivateAccess() error {
	now := time.Now()
	grants := []PrivateGrant{}
	for id, lease := range m.receivers {
		receiver, exists := m.peers[peerSlot(Peer{DeviceID: lease.DeviceID, Purpose: PrivatePurpose})]
		if !exists || !now.Before(lease.Expires) {
			delete(m.receivers, id)
			continue
		}
		for _, source := range m.peers {
			if source.Purpose == PrivatePurpose && source.DeviceID != lease.DeviceID {
				grants = append(grants, PrivateGrant{m.config.Address(source.Host), m.config.Address(receiver.Host), FilesReceiverPort})
			}
		}
	}
	sort.Slice(grants, func(i, j int) bool {
		if grants[i].Source != grants[j].Source {
			return grants[i].Source < grants[j].Source
		}
		return grants[i].Destination < grants[j].Destination
	})
	raw, _ := json.Marshal(grants)
	fingerprint := sha256.Sum256(raw)
	if m.privatePolicy == fingerprint {
		return nil
	}
	if backend, ok := m.backend.(privateAccessBackend); ok {
		if err := backend.SetPrivateAccess(grants); err != nil {
			return err
		}
	} else if len(grants) != 0 {
		return errors.New("network helper backend does not support private receiver grants")
	}
	m.privatePolicy = fingerprint
	return nil
}

func (m *Manager) privatePeerLocked(id string) (Peer, error) {
	if !ValidID(id) {
		return Peer{}, errors.New("invalid device")
	}
	if err := m.reconcile(); err != nil {
		return Peer{}, err
	}
	peer, exists := m.peers[peerSlot(Peer{DeviceID: id, Purpose: PrivatePurpose})]
	if !exists {
		return Peer{}, errors.New("connect this device's private-service transport first")
	}
	return peer, nil
}

func (m *Manager) receiverTarget(lease receiverLease) PrivateTarget {
	peer := m.peers[peerSlot(Peer{DeviceID: lease.DeviceID, Purpose: PrivatePurpose})]
	return PrivateTarget{ID: "receiver." + lease.ID, Name: "Files receiver", DeviceID: lease.DeviceID,
		Address: strings.TrimSuffix(m.config.Address(peer.Host), "/32"), Port: FilesReceiverPort, ExpiresAt: &lease.Expires}
}

func (m *Manager) PrivateTargets(id string) ([]PrivateTarget, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, err := m.privatePeerLocked(id); err != nil {
		return nil, err
	}
	result := []PrivateTarget{m.probeTarget()}
	for _, lease := range m.receivers {
		if lease.DeviceID != id {
			result = append(result, m.receiverTarget(lease))
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result, nil
}

func (m *Manager) RegisterReceiver(id string) (PrivateTarget, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, err := m.privatePeerLocked(id); err != nil {
		return PrivateTarget{}, err
	}
	if _, ok := m.backend.(privateAccessBackend); !ok {
		return PrivateTarget{}, errors.New("update the private access backend first")
	}
	for key, lease := range m.receivers {
		if lease.DeviceID == id {
			lease.Expires = time.Now().UTC().Add(receiverLifetime)
			m.receivers[key] = lease
			return m.receiverTarget(lease), nil
		}
	}
	if len(m.receivers) >= 16 {
		return PrivateTarget{}, errors.New("private receiver limit reached")
	}
	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return PrivateTarget{}, err
	}
	lease := receiverLease{ID: hex.EncodeToString(token), DeviceID: id, Expires: time.Now().UTC().Add(receiverLifetime)}
	m.receivers[lease.ID] = lease
	if err := m.syncPrivateAccess(); err != nil {
		delete(m.receivers, lease.ID)
		return PrivateTarget{}, err
	}
	return m.receiverTarget(lease), nil
}

func (m *Manager) RemoveReceiver(id string) error {
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for key, lease := range m.receivers {
		if lease.DeviceID == id {
			delete(m.receivers, key)
		}
	}
	return m.syncPrivateAccess()
}

func (c Client) PrivateTargets(id string) ([]PrivateTarget, error) {
	if !ValidID(id) {
		return nil, errors.New("invalid device")
	}
	var result []PrivateTarget
	err := c.request("GET", "/private-targets/"+id, nil, &result)
	return result, err
}
func (c Client) RegisterReceiver(id string) (PrivateTarget, error) {
	var result PrivateTarget
	if !ValidID(id) {
		return result, errors.New("invalid device")
	}
	err := c.request("POST", "/private-receivers/"+id, nil, &result)
	return result, err
}
func (c Client) RemoveReceiver(id string) error {
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	return c.request("DELETE", "/private-receivers/"+id, nil, nil)
}

func (m *Manager) registerPrivateAccessEndpoints(mux *http.ServeMux) {
	reply := func(w http.ResponseWriter, value any, err error) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if err != nil {
			w.WriteHeader(409)
			value = map[string]string{"error": err.Error()}
		}
		_ = json.NewEncoder(w).Encode(value)
	}
	mux.HandleFunc("GET /private-targets/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, e := m.PrivateTargets(r.PathValue("id"))
		reply(w, v, e)
	})
	mux.HandleFunc("POST /private-receivers/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, e := m.RegisterReceiver(r.PathValue("id"))
		reply(w, v, e)
	})
	mux.HandleFunc("DELETE /private-receivers/{id}", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"removed": true}, m.RemoveReceiver(r.PathValue("id")))
	})
}
