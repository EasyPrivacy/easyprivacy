package vpn

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrivateAndInternetPeersRemainIndependent(t *testing.T) {
	c := fixtureConfig(t)
	dir := t.TempDir()
	id := strings.Repeat("d", 64)
	auth := map[string]bool{id: true}
	backend := &fakeBackend{peers: map[string]Peer{}}
	manager, err := NewManager(c, dir, backend, func() (map[string]bool, error) { return auth, nil })
	if err != nil {
		t.Fatal(err)
	}
	internetKey, privateKey := publicKey(t), publicKey(t)
	internet, err := manager.RegisterExit(id, internetKey, "vps")
	if err != nil {
		t.Fatal(err)
	}
	private, err := manager.RegisterPrivate(id, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	var backup []Peer
	if err := ReadPrivate(filepath.Join(dir, "peers.pre-private.json"), &backup); err != nil || len(backup) != 1 || backup[0].PublicKey != internetKey || backup[0].Purpose != "" {
		t.Fatal("legacy rollback snapshot was not preserved", err)
	}
	if internet.Address == private.Address || len(backend.peers) != 2 {
		t.Fatal("private registration replaced the Internet peer")
	}
	if _, err = manager.RegisterPrivate(id, internetKey); err == nil {
		t.Fatal("same key accepted for independent transports")
	}
	restored, err := NewManager(c, dir, backend, func() (map[string]bool, error) { return auth, nil })
	if err != nil {
		t.Fatal(err)
	}
	again, err := restored.RegisterPrivate(id, privateKey)
	if err != nil || again.Address != private.Address {
		t.Fatal("private state did not survive reload", err)
	}
	if err = restored.Remove(id); err != nil {
		t.Fatal(err)
	}
	if _, ok := backend.peers[privateKey]; !ok {
		t.Fatal("Internet disconnect removed private membership")
	}
	if _, err = restored.RegisterExit(id, internetKey, "vps"); err != nil {
		t.Fatal(err)
	}
	if err = restored.RemovePrivate(id); err != nil {
		t.Fatal(err)
	}
	if _, ok := backend.peers[internetKey]; !ok {
		t.Fatal("private disconnect removed Internet peer")
	}
	if _, err = restored.RegisterPrivate(id, privateKey); err != nil {
		t.Fatal(err)
	}
	auth[id] = false
	if err = restored.reconcile(); err != nil {
		t.Fatal(err)
	}
	if len(backend.peers) != 0 {
		t.Fatal("revoked parent retained a child peer")
	}
}

func TestPrivateMembershipCannotForwardToInternetOrSpoofLegacyRole(t *testing.T) {
	c := fixtureConfig(t)
	rules := peerRules(c, Peer{DeviceID: strings.Repeat("e", 64), Host: 3, Purpose: PrivatePurpose})
	if len(rules) != 3 || !strings.Contains(strings.Join(rules[0].args, " "), "-j "+privateChain) || rules[1].chain != "INPUT" || !strings.Contains(strings.Join(rules[1].args, " "), "-j DROP") {
		t.Fatal("private membership lacks forwarding guard")
	}
	id := strings.Repeat("e", 64)
	backend := &fakeBackend{peers: map[string]Peer{}}
	manager, err := NewManager(c, t.TempDir(), backend, func() (map[string]bool, error) { return map[string]bool{id: true}, nil })
	if err != nil {
		t.Fatal(err)
	}
	body := "{\"device_id\":\"" + id + "\",\"public_key\":\"" + publicKey(t) + "\",\"purpose\":\"private-services\"}"
	req := httptest.NewRequest("POST", "/peers", strings.NewReader(body))
	res := httptest.NewRecorder()
	manager.Handler().ServeHTTP(res, req)
	if res.Code == 200 {
		t.Fatal("legacy endpoint accepted a caller-selected role")
	}
	if len(backend.peers) != 0 {
		t.Fatal("rejected request changed peers")
	}
}

func TestParentRevocationWithoutConfiguredNetwork(t *testing.T) {
	dir := t.TempDir()
	client := Client{SocketPath: filepath.Join(dir, "missing.sock"), ConfigMarker: filepath.Join(dir, "vpn.json")}
	id := strings.Repeat("c", 64)
	if err := client.RemoveDevice(id); err != nil {
		t.Fatal("an unconfigured network blocked device revocation", err)
	}
	if err := os.WriteFile(client.ConfigMarker, []byte("configured"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := client.RemoveDevice(id); err == nil {
		t.Fatal("failed removal of a configured network was hidden")
	}
}
