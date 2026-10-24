package vpn

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestPrivateReceiverFixture(t *testing.T) {
	if os.Getenv("EP_PRIVATE_RECEIVER_FIXTURE") != "1" {
		t.Skip("private network fixture")
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for range 2048 {
			if _, err := w.Write([]byte(strings.Repeat("private-data", 128))); err != nil {
				return
			}
		}
	})
	go http.ListenAndServe(":41932", handler)
	if err := http.ListenAndServe(":41931", handler); err != nil {
		t.Fatal(err)
	}
}

func TestLinuxPrivateReceiverIsolation(t *testing.T) {
	if os.Getenv("EPVPN_NETWORK_TEST") != "1" {
		t.Skip("run scripts/test-vpn-network.sh as root")
	}
	current, _ := os.Readlink("/proc/self/ns/net")
	initial, _ := os.Readlink("/proc/1/ns/net")
	if os.Geteuid() != 0 || current == initial {
		t.Fatal("network tests require a private root network namespace")
	}
	run := func(input string, args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, args[0], args[1:]...)
		cmd.Stdin = strings.NewReader(input)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%s failed: %v: %s", args[0], err, out)
		}
		return strings.TrimSpace(string(out))
	}
	ip := func(args ...string) { run("", append([]string{"ip"}, args...)...) }
	ip("link", "set", "lo", "up")
	for i, ns := range []string{"sender", "receiver"} {
		ip("netns", "add", ns)
		host := fmt.Sprintf("v%d", i)
		prefix := fmt.Sprintf("10.20%d.0.", i)
		ip("link", "add", host, "type", "veth", "peer", "name", "remote")
		ip("link", "set", "remote", "netns", ns)
		ip("addr", "add", prefix+"1/24", "dev", host)
		ip("link", "set", host, "up")
		ip("-n", ns, "link", "set", "lo", "up")
		ip("-n", ns, "addr", "add", prefix+"2/24", "dev", "remote")
		ip("-n", ns, "link", "set", "remote", "up")
		ip("-n", ns, "route", "add", "default", "via", prefix+"1")
	}
	run("", "sysctl", "-w", "net.ipv4.ip_forward=1")
	// Deliberately permissive host policy: managed rules must provide isolation.
	run("", "iptables", "-P", "FORWARD", "ACCEPT")
	c := fixtureConfig(t)
	c.Schema = 2
	c.PrivateOnly = true
	c.Uplink = ""
	c.DNS = nil
	c.Endpoint = "10.200.0.1:51821"
	backend := &Linux{}
	if err := backend.Up(c); err != nil {
		t.Fatal(err)
	}
	defer backend.Down()
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	allowed := map[string]bool{a: true, b: true}
	m, err := NewManager(c, t.TempDir(), backend, func() (map[string]bool, error) { return allowed, nil })
	if err != nil {
		t.Fatal(err)
	}
	profiles := make([]PrivateProfile, 2)
	for i, ns := range []string{"sender", "receiver"} {
		key, err := GenerateKey()
		if err != nil {
			t.Fatal(err)
		}
		client := c
		client.PrivateKey = key
		id := a
		if i == 1 {
			id = b
		}
		profile, err := m.RegisterPrivate(id, client.PublicKey())
		if err != nil {
			t.Fatal(err)
		}
		profiles[i] = profile
		ip("-n", ns, "link", "add", "private0", "type", "wireguard")
		endpoint := fmt.Sprintf("10.20%d.0.1:51821", i)
		text := fmt.Sprintf("[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 1\n", key, c.PublicKey(), endpoint)
		run(text, "ip", "netns", "exec", ns, "wg", "setconf", "private0", "/dev/stdin")
		ip("-n", ns, "addr", "add", profile.Address, "dev", "private0")
		ip("-n", ns, "link", "set", "private0", "mtu", "1280", "up")
		ip("-n", ns, "route", "add", c.Subnet, "dev", "private0")
	}
	fixture := exec.Command("ip", "netns", "exec", "receiver", os.Args[0], "-test.run", "^TestPrivateReceiverFixture$")
	fixture.Env = append(os.Environ(), "EP_PRIVATE_RECEIVER_FIXTURE=1")
	if err = fixture.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { fixture.Process.Kill(); fixture.Wait() }()
	for range 50 {
		conn, e := net.DialTimeout("tcp", "10.201.0.2:41931", 100*time.Millisecond)
		if e == nil {
			conn.Close()
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	receiverAddress := strings.TrimSuffix(profiles[1].Address, "/32")
	blocked := func(address string, port int) {
		t.Helper()
		cmd := exec.Command("ip", "netns", "exec", "sender", "python3", "-c", fmt.Sprintf("import socket; s=socket.create_connection(('%s',%d),1); s.close()", address, port))
		if cmd.Run() == nil {
			t.Fatalf("ungranted private connection succeeded: %s:%d", address, port)
		}
	}
	blocked(receiverAddress, FilesReceiverPort)
	lease, err := m.RegisterReceiver(b)
	if err != nil {
		t.Fatal(err)
	}
	if lease.Port != FilesReceiverPort {
		t.Fatal("unexpected receiver port")
	}
	// Real multi-megabyte bytes through two kernel WireGuard peers and core forwarding.
	transfer := fmt.Sprintf("import hashlib,urllib.request; data=urllib.request.urlopen('http://%s:41931',timeout=5).read(); assert len(data)==3145728; assert hashlib.sha256(data).digest()==hashlib.sha256(b'private-data'*262144).digest()", receiverAddress)
	run("", "ip", "netns", "exec", "sender", "python3", "-c", transfer)
	blocked(receiverAddress, 41932)
	coreAddress := strings.TrimSuffix(c.Address(1), "/32")
	probe := fmt.Sprintf("import socket; s=socket.create_connection(('%s',41930),3); s.settimeout(3); n=bytes(range(32)); s.sendall(n); r=b''\nwhile len(r)<32: r+=s.recv(32-len(r))\nassert r==n", coreAddress)
	run("", "ip", "netns", "exec", "sender", "python3", "-c", probe)
	blocked(coreAddress, 51821)
	// A client sending a public route still cannot use this network as an exit.
	ip("addr", "add", "203.0.113.8/32", "dev", "lo")
	ip("-n", "sender", "route", "add", "203.0.113.8/32", "dev", "private0")
	blocked("203.0.113.8", 41930)
	if raw := run("", "iptables-save", "-t", "nat"); strings.Contains(raw, "MASQUERADE") {
		t.Fatal("private-only setup enabled Internet NAT")
	}
	if err = m.RemoveReceiver(b); err != nil {
		t.Fatal(err)
	}
	blocked(receiverAddress, FilesReceiverPort)
	if _, err = m.RegisterReceiver(b); err != nil {
		t.Fatal(err)
	}
	m.mu.Lock()
	for key, entry := range m.receivers {
		entry.Expires = time.Now().Add(-time.Second)
		m.receivers[key] = entry
	}
	err = m.reconcile()
	m.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	blocked(receiverAddress, FilesReceiverPort)
	if _, err = m.RegisterReceiver(b); err != nil {
		t.Fatal(err)
	}
	allowed[b] = false
	m.mu.Lock()
	err = m.reconcile()
	m.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	blocked(receiverAddress, FilesReceiverPort)
	if err = backend.Down(); err != nil {
		t.Fatal(err)
	}
	if raw := run("", "iptables-save"); strings.Contains(raw, privateTag) || strings.Contains(raw, "easyprivacy-peer-") {
		t.Fatal("private firewall rules survived shutdown")
	}
	t.Log("private-only transfer, probe, port isolation, no exit/NAT, expiry, receiver removal and parent revocation passed")
}
