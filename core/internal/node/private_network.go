package node

import (
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"net/http"
)

func (s *Server) privatePeer(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	var input struct {
		PublicKey string `json:"public_key"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	if _, err := vpn.Key(input.PublicKey); err != nil {
		writeError(w, 400, "Invalid private transport public key.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, active := s.devices.Active(current.DeviceID); !active {
		writeError(w, 401, "Device authorization was revoked.")
		return
	}
	control, ok := s.vpn.(vpn.PrivateControl)
	if !ok {
		writeError(w, 503, "Update the node network helper for private-service connections.")
		return
	}
	profile, err := control.RegisterPrivate(current.DeviceID, input.PublicKey)
	if err != nil {
		writeError(w, 503, err.Error())
		return
	}
	writeJSON(w, 200, profile)
}

func (s *Server) privateDisconnect(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	control, ok := s.vpn.(vpn.PrivateControl)
	if !ok {
		writeError(w, 503, "Private-service connections are not configured.")
		return
	}
	if err := control.RemovePrivate(current.DeviceID); err != nil {
		writeError(w, 503, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"disconnected": true})
}

func (s *Server) privateStatus(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	control, ok := s.vpn.(vpn.PrivateControl)
	if !ok {
		writeError(w, 503, "Private-service connections are not configured.")
		return
	}
	status, err := control.PrivateStatus(current.DeviceID)
	if err != nil {
		writeError(w, 503, err.Error())
		return
	}
	writeJSON(w, 200, status)
}

func (s *Server) privateServices(w http.ResponseWriter, r *http.Request) {
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
	control, ok := s.vpn.(vpn.PrivateServicesControl)
	if !ok {
		writeError(w, 503, "Update the node network helper for private services.")
		return
	}
	targets, err := control.PrivateTargets(current.DeviceID)
	if err != nil {
		writeError(w, 503, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"protocol": 1, "services": targets})
}

func (s *Server) privateReceiver(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	var input struct {
		Capability string `json:"capability"`
		Name       string `json:"name,omitempty"`
	}
	if !readRequest(w, r, &input) {
		return
	}
	if input.Capability != "files" && input.Capability != "drive" {
		writeError(w, 400, "Only Files and Drive receivers are supported.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, active := s.devices.Active(current.DeviceID); !active {
		writeError(w, 401, "Device authorization was revoked.")
		return
	}
	control, ok := s.vpn.(vpn.PrivateServicesControl)
	if !ok {
		writeError(w, 503, "Update the node network helper for private receivers.")
		return
	}
	var target vpn.PrivateTarget
	var err error
	if input.Capability == "drive" {
		if drive, ok := s.vpn.(vpn.DriveControl); ok {
			target, err = drive.RegisterDrive(current.DeviceID, input.Name)
		} else {
			writeError(w, 503, "Update the network helper for Drive nodes.")
			return
		}
	} else {
		target, err = control.RegisterReceiver(current.DeviceID)
	}
	if err != nil {
		writeError(w, 503, err.Error())
		return
	}
	writeJSON(w, 200, target)
}

func (s *Server) privateReceiverDisconnect(w http.ResponseWriter, r *http.Request) {
	current, ok := s.authenticateDevice(r)
	if !ok {
		writeError(w, 403, "A paired device connection is required.")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	control, ok := s.vpn.(vpn.PrivateServicesControl)
	if !ok {
		writeError(w, 503, "Private receivers are not configured.")
		return
	}
	if err := control.RemoveReceiver(current.DeviceID); err != nil {
		writeError(w, 503, err.Error())
		return
	}
	writeJSON(w, 200, map[string]bool{"disconnected": true})
}
