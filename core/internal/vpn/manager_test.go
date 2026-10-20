package vpn

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeBackend struct {
	peers map[string]Peer
	fail  string
}

func (b *fakeBackend) Up(Config) error { return nil }
func (b *fakeBackend) Down() error     { return nil }
func (b *fakeBackend) SetPeer(_ Config, p Peer) error {
	if p.PublicKey == b.fail {
		return errors.New("fixture apply failure")
	}
	b.peers[p.PublicKey] = p
	return nil
}
func (b *fakeBackend) RemovePeer(key string) error { delete(b.peers, key); return nil }
func (b *fakeBackend) PeerStatus(key string) (Status, error) {
	_, ok := b.peers[key]
	return Status{Active: ok}, nil
}
func fixtureConfig(t *testing.T) Config {
	t.Helper()
	key, e := GenerateKey()
	if e != nil {
		t.Fatal(e)
	}
	return Config{Schema: 1, Name: "Test VPS", Endpoint: "203.0.113.8:51821", Port: 51821, Subnet: "10.87.0.0/24", Uplink: "eth0", DNS: []string{"1.1.1.1"}, PrivateKey: key}
}
func publicKey(t *testing.T) string { c := fixtureConfig(t); return c.PublicKey() }
func TestVPNAuthorizationKeysAddressesPersistenceAndRevocation(t *testing.T) {
	c := fixtureConfig(t)
	dir := t.TempDir()
	id1, id2 := strings.Repeat("1", 64), strings.Repeat("2", 64)
	auth := map[string]bool{id1: true, id2: true}
	backend := &fakeBackend{peers: map[string]Peer{}}
	m, e := NewManager(c, dir, backend, func() (map[string]bool, error) { return auth, nil })
	if e != nil {
		t.Fatal(e)
	}
	key1, key2 := publicKey(t), publicKey(t)
	a, e := m.Register(id1, key1)
	if e != nil {
		t.Fatal(e)
	}
	b, e := m.Register(id2, key2)
	if e != nil {
		t.Fatal(e)
	}
	if a.Address == b.Address || a.PublicKey != c.PublicKey() {
		t.Fatal("peer addressing or server identity is wrong")
	}
	if _, e = m.Register(id2, key1); e == nil {
		t.Fatal("another device's public key was stolen")
	}
	if _, e = m.Register(strings.Repeat("3", 64), publicKey(t)); e == nil {
		t.Fatal("unpaired device authorized")
	}
	restored, e := NewManager(c, dir, backend, func() (map[string]bool, error) { return auth, nil })
	if e != nil {
		t.Fatal(e)
	}
	again, e := restored.Register(id1, key1)
	if e != nil || again.Address != a.Address {
		t.Fatal("address did not survive restart")
	}
	auth[id1] = false
	if e = restored.reconcile(); e != nil {
		t.Fatal(e)
	}
	if _, ok := backend.peers[key1]; ok {
		t.Fatal("revoked device retained a VPN peer")
	}
	if _, e = restored.Register(id1, key1); e == nil {
		t.Fatal("revoked device re-enrolled")
	}
}
func TestVPNFailedApplyRollsBackAndAuthorizationFailureDisablesPeers(t *testing.T) {
	c := fixtureConfig(t)
	id := strings.Repeat("a", 64)
	backend := &fakeBackend{peers: map[string]Peer{}}
	broken := false
	m, e := NewManager(c, t.TempDir(), backend, func() (map[string]bool, error) {
		if broken {
			return nil, errors.New("bad device records")
		}
		return map[string]bool{id: true}, nil
	})
	if e != nil {
		t.Fatal(e)
	}
	first := publicKey(t)
	if _, e = m.Register(id, first); e != nil {
		t.Fatal(e)
	}
	backend.fail = publicKey(t)
	if _, e = m.Register(id, backend.fail); e == nil {
		t.Fatal("failed kernel update accepted")
	}
	if m.peers[id].PublicKey != first {
		t.Fatal("failed rotation replaced persistent authorization")
	}
	broken = true
	if e = m.reconcile(); e == nil {
		t.Fatal("bad authorization records accepted")
	}
	if len(backend.peers) != 0 {
		t.Fatal("peers survived unavailable authorization")
	}
}
func TestVPNStateAndSetupValidation(t *testing.T) {
	c := fixtureConfig(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "vpn.json")
	if e := SavePrivate(path, c); e != nil {
		t.Fatal(e)
	}
	if _, e := LoadConfig(dir); e != nil {
		t.Fatal(e)
	}
	if e := os.Chmod(path, 0644); e != nil {
		t.Fatal(e)
	}
	if _, e := LoadConfig(dir); e == nil {
		t.Fatal("publicly readable key accepted")
	}
	for _, change := range []func(*Config){func(c *Config) { c.Uplink = "eth0;reboot" }, func(c *Config) { c.Subnet = "0.0.0.0/0" }, func(c *Config) { c.Endpoint = "example.com:443\nPostUp = x" }, func(c *Config) { c.PrivateKey = "bad" }, func(c *Config) { c.Uplink = "wg0" }} {
		v := c
		change(&v)
		if v.Validate() == nil {
			t.Fatal("invalid privileged configuration accepted")
		}
	}
	if CheckRoutes(c.Subnet, "default via 192.0.2.1 dev eth0\n10.87.0.0/16 dev wg0\n") == nil {
		t.Fatal("overlapping network accepted")
	}
	if CheckRoutes(c.Subnet, "default via 192.0.2.1 dev eth0\n10.86.0.0/24 dev wg0\n") != nil {
		t.Fatal("unrelated route rejected")
	}
}
