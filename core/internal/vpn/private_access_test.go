package vpn

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestDriveLeaseHasDistinctRoleAndUsesExistingPrivatePort(t *testing.T) {
	c := fixtureConfig(t)
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	allowed := map[string]bool{a: true, b: true}
	backend := &fakeBackend{peers: map[string]Peer{}}
	m, err := NewManager(c, t.TempDir(), backend, func() (map[string]bool, error) { return allowed, nil })
	if err != nil {
		t.Fatal(err)
	}
	if _, err = m.RegisterPrivate(a, publicKey(t)); err != nil {
		t.Fatal(err)
	}
	if _, err = m.RegisterPrivate(b, publicKey(t)); err != nil {
		t.Fatal(err)
	}
	lease, err := m.RegisterDrive(b, "Storage")
	if err != nil {
		t.Fatal(err)
	}
	if lease.Kind != "drive" || lease.Name != "Storage" || lease.Port != FilesReceiverPort {
		t.Fatal("invalid Drive target", lease)
	}
	if _, err = m.RegisterReceiver(b); err == nil {
		t.Fatal("Drive identity could silently change receiver roles")
	}
	targets, err := m.PrivateTargets(a)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, target := range targets {
		if target.ID == lease.ID && target.Kind == "drive" {
			found = true
		}
	}
	if !found {
		t.Fatal("Drive was not discoverable")
	}
	renewed, err := m.RegisterDrive(b, "Updated storage")
	if err != nil || renewed.ID != lease.ID || renewed.Name != "Updated storage" {
		t.Fatal("Drive renewal lost identity")
	}
	delete(allowed, b)
	targets, err = m.PrivateTargets(a)
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range targets {
		if target.ID == lease.ID {
			t.Fatal("revoked Drive stayed discoverable")
		}
	}
}
func TestPrivateReceiverLeasesRestrictPortsPeersAndLifetime(t *testing.T) {
	c := fixtureConfig(t)
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	allowed := map[string]bool{a: true, b: true}
	backend := &fakeBackend{peers: map[string]Peer{}}
	manager, err := NewManager(c, t.TempDir(), backend, func() (map[string]bool, error) { return allowed, nil })
	if err != nil {
		t.Fatal(err)
	}
	internet, err := manager.Register(a, publicKey(t))
	if err != nil {
		t.Fatal(err)
	}
	sender, err := manager.RegisterPrivate(a, publicKey(t))
	if err != nil {
		t.Fatal(err)
	}
	recipient, err := manager.RegisterPrivate(b, publicKey(t))
	if err != nil {
		t.Fatal(err)
	}
	lease, err := manager.RegisterReceiver(b)
	if err != nil {
		t.Fatal(err)
	}
	if len(backend.grants) != 1 || backend.grants[0].Source != sender.Address || backend.grants[0].Source == internet.Address || backend.grants[0].Destination != recipient.Address || backend.grants[0].Port != FilesReceiverPort {
		t.Fatal("receiver policy includes an ungranted peer or port", backend.grants)
	}
	targets, err := manager.PrivateTargets(a)
	if err != nil || len(targets) != 2 {
		t.Fatal("sender cannot discover receiver", targets, err)
	}
	own, err := manager.PrivateTargets(b)
	if err != nil || len(own) != 1 || own[0].ID != "core.probe" {
		t.Fatal("receiver exposed to its own device", own, err)
	}
	renewed, err := manager.RegisterReceiver(b)
	if err != nil || renewed.ID != lease.ID {
		t.Fatal("renewal replaced receiver identity", err)
	}
	for key, entry := range manager.receivers {
		entry.Expires = time.Now().Add(-time.Second)
		manager.receivers[key] = entry
	}
	targets, err = manager.PrivateTargets(a)
	if err != nil || len(targets) != 1 || len(backend.grants) != 0 {
		t.Fatal("expired receiver remained accessible", err)
	}
	fresh, err := manager.RegisterReceiver(b)
	if err != nil || fresh.ID == lease.ID {
		t.Fatal("expired receiver identity reused", err)
	}
	if err = manager.RemovePrivate(b); err != nil {
		t.Fatal(err)
	}
	if len(manager.receivers) != 0 || len(backend.grants) != 0 {
		t.Fatal("private disconnect retained receiver grants")
	}
	if _, err = manager.RegisterReceiver(b); err == nil {
		t.Fatal("receiver registered without private membership")
	}
	if _, err = manager.RegisterPrivate(b, publicKey(t)); err != nil {
		t.Fatal(err)
	}
	if _, err = manager.RegisterReceiver(b); err != nil {
		t.Fatal(err)
	}
	allowed[b] = false
	if _, err = manager.PrivateTargets(a); err != nil {
		t.Fatal(err)
	}
	if len(manager.receivers) != 0 || len(backend.grants) != 0 {
		t.Fatal("parent revocation retained receiver grants")
	}
}

func TestPrivateOnlyConfigurationPreservesLegacyInternetDefault(t *testing.T) {
	legacy := fixtureConfig(t)
	raw, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "private_only") {
		t.Fatal("legacy configuration was silently migrated")
	}
	private := legacy
	private.Schema = 2
	private.PrivateOnly = true
	private.Uplink = ""
	private.DNS = nil
	if err = private.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, rule := range rules(private) {
		if rule.table == "nat" || strings.Contains(strings.Join(rule.args, " "), "MASQUERADE") {
			t.Fatal("private-only network enables NAT")
		}
	}
	id := strings.Repeat("c", 64)
	backend := &fakeBackend{peers: map[string]Peer{}}
	manager, err := NewManager(private, t.TempDir(), backend, func() (map[string]bool, error) { return map[string]bool{id: true}, nil })
	if err != nil {
		t.Fatal(err)
	}
	info, _ := manager.Info()
	if info.Ready {
		t.Fatal("private-only network advertised an Internet exit")
	}
	if _, err = manager.Register(id, publicKey(t)); err == nil {
		t.Fatal("Internet peer registered on private-only network")
	}
	profile, err := manager.RegisterPrivate(id, publicKey(t))
	if err != nil || profile.Protocol != 1 || profile.Probe.Port != PrivateProbePort {
		t.Fatal("private membership unavailable", err)
	}
	private.PrivateOnly = false
	private.Uplink = legacy.Uplink
	private.DNS = legacy.DNS
	if err = private.Validate(); err != nil || private.PrivateKey != legacy.PrivateKey || private.Subnet != legacy.Subnet {
		t.Fatal("Internet enablement changed network identity", err)
	}
}
