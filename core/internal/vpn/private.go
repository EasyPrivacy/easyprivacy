package vpn

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
)

func peerSlot(p Peer) string {
	if p.Purpose == "" {
		return p.DeviceID
	}
	return p.DeviceID + ":" + p.Purpose
}

func (m *Manager) RegisterPrivate(id, key string) (PrivateProfile, error) {
	p, err := m.register(Peer{DeviceID: id, PublicKey: key, Purpose: PrivatePurpose})
	if err != nil {
		return PrivateProfile{}, err
	}
	return PrivateProfile{Protocol: 1, PublicKey: p.PublicKey, Endpoint: p.Endpoint, Address: p.Address,
		Subnet: m.config.Subnet, MTU: p.MTU, Keepalive: p.Keepalive, Probe: m.probeTarget()}, nil
}

func (m *Manager) RemovePrivate(id string) error {
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	slot := peerSlot(Peer{DeviceID: id, Purpose: PrivatePurpose})
	p, exists := m.peers[slot]
	if !exists {
		return nil
	}
	if err := m.backend.RemovePeer(p.PublicKey); err != nil {
		return err
	}
	delete(m.peers, slot)
	if err := m.syncPrivateAccess(); err != nil {
		return err
	}
	return m.save()
}

func (m *Manager) PrivateStatus(id string) (Status, error) {
	if !ValidID(id) {
		return Status{}, errors.New("invalid device")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.reconcile(); err != nil {
		return Status{}, err
	}
	p, exists := m.peers[peerSlot(Peer{DeviceID: id, Purpose: PrivatePurpose})]
	if !exists {
		return Status{}, nil
	}
	return m.backend.PeerStatus(p.PublicKey)
}

// RemoveDevice is used after parent authorization is revoked. Legacy VPN
// disconnect deliberately remains scoped to the Internet/Home peer.
func (m *Manager) RemoveDevice(id string) error {
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, p := range m.peers {
		if p.DeviceID == id {
			if err := m.backend.RemovePeer(p.PublicKey); err != nil {
				return err
			}
		}
	}
	for slot, p := range m.peers {
		if p.DeviceID == id {
			delete(m.peers, slot)
		}
	}
	if err := m.syncPrivateAccess(); err != nil {
		return err
	}
	return m.save()
}

func (c Client) RegisterPrivate(id, key string) (PrivateProfile, error) {
	var result PrivateProfile
	err := c.request("POST", "/private-peers", map[string]string{"device_id": id, "public_key": key}, &result)
	return result, err
}
func (c Client) RemovePrivate(id string) error {
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	return c.request("DELETE", "/private-peers/"+id, nil, nil)
}
func (c Client) PrivateStatus(id string) (Status, error) {
	var result Status
	if !ValidID(id) {
		return result, errors.New("invalid device")
	}
	err := c.request("GET", "/private-peers/"+id, nil, &result)
	return result, err
}
func (c Client) RemoveDevice(id string) error {
	if !ValidID(id) {
		return errors.New("invalid device")
	}
	err := c.request("DELETE", "/devices/"+id+"/peers", nil, nil)
	if err != nil && c.ConfigMarker != "" {
		if _, statErr := os.Stat(c.ConfigMarker); errors.Is(statErr, os.ErrNotExist) {
			return nil
		}
	}
	return err
}

func (m *Manager) registerPrivateEndpoints(mux *http.ServeMux) {
	reply := func(w http.ResponseWriter, value any, err error) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if err != nil {
			w.WriteHeader(409)
			value = map[string]string{"error": err.Error()}
		}
		_ = json.NewEncoder(w).Encode(value)
	}
	mux.HandleFunc("POST /private-peers", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		defer r.Body.Close()
		var input struct {
			DeviceID  string
			PublicKey string
		}
		// Decode explicit wire names, without accepting caller-selected routes/roles.
		var wire map[string]json.RawMessage
		d := json.NewDecoder(r.Body)
		var extra any
		if d.Decode(&wire) != nil || d.Decode(&extra) != io.EOF || len(wire) != 2 ||
			json.Unmarshal(wire["device_id"], &input.DeviceID) != nil ||
			json.Unmarshal(wire["public_key"], &input.PublicKey) != nil {
			reply(w, nil, errors.New("invalid private peer request"))
			return
		}
		value, err := m.RegisterPrivate(input.DeviceID, input.PublicKey)
		reply(w, value, err)
	})
	mux.HandleFunc("DELETE /private-peers/{id}", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"removed": true}, m.RemovePrivate(r.PathValue("id")))
	})
	mux.HandleFunc("GET /private-peers/{id}", func(w http.ResponseWriter, r *http.Request) {
		value, err := m.PrivateStatus(r.PathValue("id"))
		reply(w, value, err)
	})
	mux.HandleFunc("DELETE /devices/{id}/peers", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]bool{"removed": true}, m.RemoveDevice(r.PathValue("id")))
	})
}
