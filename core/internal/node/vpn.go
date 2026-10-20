package node

import (
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"net/http"
)

func (s *Server) UseVPN(control vpn.Control) { s.vpn = control }
func (s *Server) vpnExits(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.authenticateDevice(r); !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	exit := vpn.Exit{ID: "vps", Name: "VPS exit", Message: "Run sudo easyprivacy-node vpn-setup on the VPS to enable its VPN exit."}
	if s.vpn != nil {
		if control, ok := s.vpn.(vpn.ServiceControl); ok {
			if exits, err := control.Exits(); err == nil {
				writeJSON(w, 200, map[string]any{"exits": exits})
				return
			}
		}
		if v, e := s.vpn.Info(); e == nil {
			exit = v
		}
	}
	writeJSON(w, 200, map[string]any{"exits": []vpn.Exit{exit}})
}
func (s *Server) vpnPeer(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	var input struct {
		ExitID    string `json:"exit_id"`
		PublicKey string `json:"public_key"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	if input.ExitID != "vps" && input.ExitID != "home" {
		writeError(w, 400, "Unknown VPN exit.")
		return
	}
	if _, e := vpn.Key(input.PublicKey); e != nil {
		writeError(w, 400, "Invalid VPN public key.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, active := s.devices.Active(current.DeviceID); !active {
		writeError(w, 401, "Device authorization was revoked.")
		return
	}
	if s.vpn == nil {
		writeError(w, 503, "Configure the VPS exit with sudo easyprivacy-node vpn-setup first.")
		return
	}
	var profile vpn.Profile
	var e error
	if control, ok := s.vpn.(vpn.ServiceControl); ok {
		profile, e = control.RegisterExit(current.DeviceID, input.PublicKey, input.ExitID)
	} else if input.ExitID == "vps" {
		profile, e = s.vpn.Register(current.DeviceID, input.PublicKey)
	} else {
		writeError(w, 503, "Update the core package for home exits.")
		return
	}
	if e != nil {
		writeError(w, 503, e.Error())
		return
	}
	writeJSON(w, 200, profile)
}
func (s *Server) vpnService(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	var input struct {
		PublicKey  string `json:"public_key"`
		Name       string `json:"name"`
		Management string `json:"management_addresses"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	if _, e := vpn.Key(input.PublicKey); e != nil {
		writeError(w, 400, "Invalid VPN public key.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, active := s.devices.Active(current.DeviceID); !active {
		writeError(w, 401, "Device authorization was revoked.")
		return
	}
	control, ok := s.vpn.(vpn.ServiceControl)
	if !ok {
		writeError(w, 503, "Update the core package and configure its VPN exit first.")
		return
	}
	profile, e := control.RegisterService(current.DeviceID, input.PublicKey, input.Name, input.Management)
	if e != nil {
		writeError(w, 503, e.Error())
		return
	}
	writeJSON(w, 200, profile)
}
func (s *Server) vpnDisconnect(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	if s.vpn != nil {
		if e := s.vpn.Remove(current.DeviceID); e != nil {
			writeError(w, 503, e.Error())
			return
		}
	}
	writeJSON(w, 200, map[string]bool{"disconnected": true})
}
func (s *Server) vpnStatus(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	if s.vpn == nil {
		writeJSON(w, 200, vpn.Status{})
		return
	}
	v, e := s.vpn.Status(current.DeviceID)
	if e != nil {
		writeError(w, 503, e.Error())
		return
	}
	writeJSON(w, 200, v)
}
