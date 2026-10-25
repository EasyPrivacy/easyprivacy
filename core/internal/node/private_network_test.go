package node

import (
	"crypto/ed25519"
	"crypto/rand"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"testing"
)

type privateNetworkFixture struct {
	vpnFixture
	privateDevice, privateRemoved, parentRemoved string
	receiverDevice, servicesDevice               string
}

func (v *privateNetworkFixture) RegisterPrivate(id, key string) (vpn.PrivateProfile, error) {
	v.privateDevice = id
	return vpn.PrivateProfile{Address: "10.87.0.3/32", Subnet: "10.87.0.0/24", MTU: 1280}, nil
}
func (v *privateNetworkFixture) RemovePrivate(id string) error { v.privateRemoved = id; return nil }
func (v *privateNetworkFixture) PrivateStatus(string) (vpn.Status, error) {
	return vpn.Status{Active: true}, nil
}
func (v *privateNetworkFixture) RemoveDevice(id string) error { v.parentRemoved = id; return nil }
func (v *privateNetworkFixture) PrivateTargets(id string) ([]vpn.PrivateTarget, error) {
	v.servicesDevice = id
	return []vpn.PrivateTarget{{ID: "core.probe", Address: "10.87.0.1", Port: vpn.PrivateProbePort}}, nil
}
func (v *privateNetworkFixture) RegisterReceiver(id string) (vpn.PrivateTarget, error) {
	v.receiverDevice = id
	return vpn.PrivateTarget{ID: "receiver.fixture", DeviceID: id, Address: "10.87.0.3", Port: vpn.FilesReceiverPort}, nil
}
func (v *privateNetworkFixture) RemoveReceiver(id string) error { v.receiverDevice = id; return nil }
func (v *privateNetworkFixture) RegisterDrive(id, name string) (vpn.PrivateTarget, error) {
	v.receiverDevice = id
	return vpn.PrivateTarget{Kind: "drive", Name: name, ID: "receiver.fixture", DeviceID: id, Address: "10.87.0.3", Port: vpn.FilesReceiverPort}, nil
}

func TestPrivateNetworkAPIBindsParentAndRevokesAllPurposes(t *testing.T) {
	s, ts, client := runningServer(t)
	backend := &privateNetworkFixture{}
	s.UseVPN(backend)
	key, _ := vpn.GenerateKey()
	body := jsonBody(map[string]string{"public_key": key})
	status, _ := request(t, client, ts.URL, "POST", "/api/v2/network/private/peer", body, "")
	if status != 403 {
		t.Fatal("anonymous private membership accepted")
	}
	_, legacy := login(t, client, ts.URL, testPassword)
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/peer", body, legacy["access_token"].(string))
	if status != 403 {
		t.Fatal("password-only private membership accepted")
	}
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	device, _ := s.devices.Add("Core app", public)
	token := deviceSession(t, s, ts, client, private)
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/peer", body, token)
	if status != 200 || backend.privateDevice != device.ID {
		t.Fatal("private membership was not bound to enrolled parent", status)
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/peer", jsonBody(map[string]string{"public_key": key, "device_id": "other-parent"}), token)
	if status != 400 {
		t.Fatal("caller-selected parent accepted")
	}
	status, _ = request(t, client, ts.URL, "GET", "/api/v2/network/private/services", "", legacy["access_token"].(string))
	if status != 403 || backend.servicesDevice != "" {
		t.Fatal("password session discovered private services")
	}
	status, _ = request(t, client, ts.URL, "GET", "/api/v2/network/private/services", "", token)
	if status != 200 || backend.servicesDevice != device.ID {
		t.Fatal("service discovery is not scoped to the enrolled parent")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/receiver", jsonBody(map[string]any{"capability": "files", "port": 22}), token)
	if status != 400 || backend.receiverDevice != "" {
		t.Fatal("caller-selected receiver port accepted")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/receiver", jsonBody(map[string]any{"capability": "files", "device_id": "other"}), token)
	if status != 400 {
		t.Fatal("receiver parent spoof accepted")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/receiver", jsonBody(map[string]string{"capability": "files"}), token)
	if status != 200 || backend.receiverDevice != device.ID {
		t.Fatal("receiver is not scoped to enrolled parent")
	}
	backend.receiverDevice = ""
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/receiver", jsonBody(map[string]string{"capability": "drive", "name": "Cloud storage"}), token)
	if status != 200 || backend.receiverDevice != device.ID {
		t.Fatal("Drive registration was not bound to the authenticated parent")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v2/network/private/disconnect", "", token)
	if status != 200 || backend.privateRemoved != device.ID || backend.removed != "" {
		t.Fatal("private disconnect changed Internet peer")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/devices/"+device.ID+"/revoke", "", token)
	if status != 200 || backend.parentRemoved != device.ID {
		t.Fatal("revocation did not use all-purpose removal")
	}
	status, _ = request(t, client, ts.URL, "GET", "/api/v2/network/private/status", "", token)
	if status != 403 {
		t.Fatal("revoked private status session remained usable")
	}
}
