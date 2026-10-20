package node

import (
	"crypto/ed25519"
	"crypto/rand"
	"github.com/easyprivacy/easyprivacy/core/internal/vpn"
	"testing"
)

type vpnFixture struct{ device, key, removed string }

func (v *vpnFixture) Info() (vpn.Exit, error) {
	return vpn.Exit{ID: "vps", Name: "My VPS", Ready: true}, nil
}
func (v *vpnFixture) Register(id, key string) (vpn.Profile, error) {
	v.device = id
	v.key = key
	return vpn.Profile{ExitID: "vps"}, nil
}
func (v *vpnFixture) Remove(id string) error            { v.removed = id; return nil }
func (v *vpnFixture) Status(string) (vpn.Status, error) { return vpn.Status{Active: true}, nil }
func TestVPNRequiresPairedSessionAndRevocationRemovesPeer(t *testing.T) {
	s, ts, client := runningServer(t)
	backend := &vpnFixture{}
	s.UseVPN(backend)
	status, _ := request(t, client, ts.URL, "GET", "/api/v1/vpn/exits", "", "")
	if status != 403 {
		t.Fatal("unauthenticated VPN discovery")
	}
	_, legacy := login(t, client, ts.URL, testPassword)
	status, _ = request(t, client, ts.URL, "GET", "/api/v1/vpn/exits", "", legacy["access_token"].(string))
	if status != 403 {
		t.Fatal("password-only VPN provisioning")
	}
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	d, _ := s.devices.Add("PC", public)
	token := deviceSession(t, s, ts, client, private)
	key, _ := vpn.GenerateKey()
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/vpn/peer", jsonBody(map[string]string{"exit_id": "vps", "public_key": key}), token)
	if status != 200 || backend.device != d.ID {
		t.Fatal("VPN registration was not bound to authenticated device")
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/devices/"+d.ID+"/revoke", "", token)
	if status != 200 || backend.removed != d.ID {
		t.Fatal("device revocation did not remove VPN authorization")
	}
	status, _ = request(t, client, ts.URL, "GET", "/api/v1/vpn/status", "", token)
	if status != 403 {
		t.Fatal("revoked VPN session survived")
	}
}

type homeVPNFixture struct {
	vpnFixture
	exit, serviceName string
}

func (v *homeVPNFixture) Exits() ([]vpn.Exit, error) {
	return []vpn.Exit{{ID: "vps", Name: "VPS", Ready: true}, {ID: "home", Name: "Home", Ready: true}}, nil
}
func (v *homeVPNFixture) RegisterExit(id, key, exit string) (vpn.Profile, error) {
	v.device = id
	v.key = key
	v.exit = exit
	return vpn.Profile{ExitID: exit}, nil
}
func (v *homeVPNFixture) RegisterService(id, key, name string, _ ...string) (vpn.ServiceProfile, error) {
	v.device = id
	v.key = key
	v.serviceName = name
	return vpn.ServiceProfile{Profile: vpn.Profile{ExitID: "home"}}, nil
}
func TestHomeServiceAPIUsesPairedIdentityAndExitSelection(t *testing.T) {
	s, ts, client := runningServer(t)
	backend := &homeVPNFixture{}
	s.UseVPN(backend)
	key, _ := vpn.GenerateKey()
	body := jsonBody(map[string]string{"public_key": key, "name": "Home"})
	status, _ := request(t, client, ts.URL, "POST", "/api/v1/vpn/service", body, "")
	if status != 403 {
		t.Fatal("anonymous site registration")
	}
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	d, _ := s.devices.Add("Home VM", public)
	token := deviceSession(t, s, ts, client, private)
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/vpn/service", body, token)
	if status != 200 || backend.device != d.ID || backend.serviceName != "Home" {
		t.Fatal("service was not bound to the authenticated identity", status)
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/vpn/peer", jsonBody(map[string]string{"public_key": key, "exit_id": "home"}), token)
	if status != 200 || backend.exit != "home" {
		t.Fatal("home selection did not reach routing helper", status)
	}
	status, _ = request(t, client, ts.URL, "POST", "/api/v1/vpn/service", jsonBody(map[string]string{"public_key": key, "name": "Home", "device_id": "someone-else"}), token)
	if status != 400 {
		t.Fatal("caller supplied another service identity")
	}
}
