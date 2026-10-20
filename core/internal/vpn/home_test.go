package vpn

import (
	"strings"
	"testing"
)

func TestHomeServiceOwnershipSelectionAndRevocation(t *testing.T) {
	c := fixtureConfig(t)
	dir := t.TempDir()
	ids := []string{strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)}
	auth := map[string]bool{ids[0]: true, ids[1]: true, ids[2]: true}
	b := &fakeBackend{peers: map[string]Peer{}}
	m, err := NewManager(c, dir, b, func() (map[string]bool, error) { return auth, nil })
	if err != nil {
		t.Fatal(err)
	}
	if _, err = m.RegisterExit(ids[0], publicKey(t), "home"); err == nil {
		t.Fatal("unknown service accepted")
	}
	site, err := m.RegisterService(ids[1], publicKey(t), "Home")
	if err != nil {
		t.Fatal(err)
	}
	if len(site.AllowedIPs) != 1 || site.AllowedIPs[0] != c.Subnet {
		t.Fatal("service received an Internet default route")
	}
	if _, err = m.RegisterService(ids[2], publicKey(t), "Other home"); err == nil {
		t.Fatal("second service stole the home route")
	}
	profile, err := m.RegisterExit(ids[0], publicKey(t), "home")
	if err != nil {
		t.Fatal(err)
	}
	if profile.ExitID != "home" || profile.ExitName != "Home" || profile.Endpoint != c.Endpoint {
		t.Fatal("client did not retain VPS transport")
	}
	if _, err = m.RegisterExit(ids[1], publicKey(t), "vps"); err == nil {
		t.Fatal("service changed role without disconnecting")
	}
	restored, err := NewManager(c, dir, b, func() (map[string]bool, error) { return auth, nil })
	if err != nil {
		t.Fatal(err)
	}
	auth[ids[1]] = false
	if err = restored.reconcile(); err != nil {
		t.Fatal(err)
	}
	if restored.peers[ids[0]].ExitID != "home" {
		t.Fatal("service revocation silently changed client exit")
	}
	if _, err = restored.RegisterExit(ids[1], publicKey(t), "home"); err == nil {
		t.Fatal("revoked service identity reused")
	}
}
