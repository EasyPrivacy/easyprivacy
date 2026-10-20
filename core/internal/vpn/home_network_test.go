package vpn

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestVPNHomeSiteFixture(t *testing.T) {
	path := os.Getenv("EPVPN_SITE_FILE")
	if path == "" {
		t.Skip("isolated fixture")
	}
	var c SiteConfig
	if err := ReadPrivate(path, &c); err != nil {
		t.Fatal(err)
	}
	if err := SiteUp(c); err != nil {
		t.Fatal(err)
	}
	defer SiteDown(c)
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM)
	defer signal.Stop(signals)
	<-signals
}
func TestVPNManagementFixture(t *testing.T) {
	if os.Getenv("EPVPN_MANAGEMENT_FIXTURE") != "1" {
		t.Skip("isolated fixture")
	}
	server := &http.Server{Addr: "192.168.70.1:18081", Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, r.RemoteAddr) })}
	if err := server.ListenAndServe(); err != nil {
		t.Fatal(err)
	}
}
func TestLinuxRoutedHomeExit(t *testing.T) {
	if os.Getenv("EPVPN_NETWORK_TEST") != "1" {
		t.Skip("run scripts/test-vpn-network.sh as root")
	}
	current, _ := os.Readlink("/proc/self/ns/net")
	initial, _ := os.Readlink("/proc/1/ns/net")
	if os.Geteuid() != 0 || current == initial {
		t.Fatal("private root network namespace required")
	}
	run := func(input string, args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, args[0], args[1:]...)
		cmd.Stdin = strings.NewReader(input)
		raw, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("fixture command %s: %v: %s", args[0], err, raw)
		}
		return strings.TrimSpace(string(raw))
	}
	ip := func(args ...string) { run("", append([]string{"ip"}, args...)...) }
	ip("link", "set", "lo", "up")
	for _, name := range []string{"client", "internet", "router", "home"} {
		ip("netns", "add", name)
		ip("-n", name, "link", "set", "lo", "up")
	}
	for _, p := range [][3]string{{"c0", "client", "10.200.0."}, {"wan0", "internet", "10.201.0."}, {"homewan", "router", "10.202.0."}} {
		ip("link", "add", p[0], "type", "veth", "peer", "name", "remote")
		ip("link", "set", "remote", "netns", p[1])
		ip("-n", p[1], "link", "set", "remote", "name", "eth0")
		ip("addr", "add", p[2]+"1/24", "dev", p[0])
		ip("link", "set", p[0], "up")
		ip("-n", p[1], "addr", "add", p[2]+"2/24", "dev", "eth0")
		ip("-n", p[1], "link", "set", "eth0", "up")
		ip("-n", p[1], "route", "add", "default", "via", p[2]+"1")
	}
	ip("-n", "router", "link", "add", "lan0", "type", "veth", "peer", "name", "homelan")
	ip("-n", "router", "link", "set", "homelan", "netns", "home")
	ip("-n", "home", "link", "set", "homelan", "name", "eth0")
	ip("-n", "router", "addr", "add", "192.168.70.1/24", "dev", "lan0")
	ip("-n", "router", "link", "set", "lan0", "up")
	ip("-n", "home", "addr", "add", "192.168.70.2/24", "dev", "eth0")
	ip("-n", "home", "link", "set", "eth0", "up")
	ip("-n", "home", "route", "add", "default", "via", "192.168.70.1")
	ip("route", "add", "default", "via", "10.201.0.2")
	ip("-n", "internet", "addr", "add", "203.0.113.8/32", "dev", "lo")
	run("", "sysctl", "-w", "net.ipv4.ip_forward=1")
	run("", "ip", "netns", "exec", "router", "sysctl", "-w", "net.ipv4.ip_forward=1")
	run("", "ip", "netns", "exec", "router", "iptables", "-t", "nat", "-A", "POSTROUTING", "-s", "192.168.70.0/24", "-o", "eth0", "-j", "MASQUERADE")
	// The physical underlay emulates the ISP. The VPS has no route to 192.168.70/24.
	run("", "iptables", "-P", "FORWARD", "DROP")
	run("", "iptables", "-A", "FORWARD", "-i", "homewan", "-o", "wan0", "-j", "ACCEPT")
	run("", "iptables", "-A", "FORWARD", "-i", "wan0", "-o", "homewan", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT")
	start := func(namespace, test, env string) *exec.Cmd {
		t.Helper()
		cmd := exec.Command("ip", "netns", "exec", namespace, os.Args[0], "-test.run", "^"+test+"$")
		cmd.Env = append(os.Environ(), env, "EPVPN_EXPECTED_SOURCE=10.202.0.2")
		var log bytes.Buffer
		cmd.Stdout = &log
		cmd.Stderr = &log
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			if t.Failed() {
				t.Log(log.String())
			}
		})
		return cmd
	}
	start("internet", "TestVPNInternetFixture", "EPVPN_INTERNET_FIXTURE=1")
	start("router", "TestVPNManagementFixture", "EPVPN_MANAGEMENT_FIXTURE=1")
	c := fixtureConfig(t)
	c.Endpoint = "10.202.0.1:51821"
	c.Uplink = "wan0"
	c.DNS = []string{"203.0.113.8"}
	backend := &Linux{}
	if err := backend.Up(c); err != nil {
		t.Fatal(err)
	}
	defer backend.Down()
	serviceID, clientID := strings.Repeat("a", 64), strings.Repeat("b", 64)
	auth := map[string]bool{serviceID: true, clientID: true}
	dir := t.TempDir()
	m, err := NewManager(c, dir, backend, func() (map[string]bool, error) { return auth, nil })
	if err != nil {
		t.Fatal(err)
	}
	siteKey, _ := GenerateKey()
	sitePublic := (Config{PrivateKey: siteKey}).PublicKey()
	site, err := m.RegisterService(serviceID, sitePublic, "My home", "192.168.70.1")
	if err != nil {
		t.Fatal(err)
	}
	sitePath := filepath.Join(t.TempDir(), "site.json")
	if err = SavePrivate(sitePath, SiteConfig{ServiceProfile: site, PrivateKey: siteKey, Uplink: "eth0"}); err != nil {
		t.Fatal(err)
	}
	start("home", "TestVPNHomeSiteFixture", "EPVPN_SITE_FILE="+sitePath)
	key, _ := GenerateKey()
	public := (Config{PrivateKey: key}).PublicKey()
	profile, err := m.RegisterExit(clientID, public, "home")
	if err != nil {
		t.Fatal(err)
	}
	ip("-n", "client", "link", "add", "epclient", "type", "wireguard")
	conf := fmt.Sprintf("[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nEndpoint = 10.200.0.1:51821\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 1\n", key, c.PublicKey())
	run(conf, "ip", "netns", "exec", "client", "wg", "setconf", "epclient", "/dev/stdin")
	ip("-n", "client", "addr", "add", profile.Address, "dev", "epclient")
	ip("-n", "client", "link", "set", "epclient", "mtu", "1280", "up")
	ip("-n", "client", "route", "replace", "default", "dev", "epclient")
	curl := []string{"ip", "netns", "exec", "client", "curl", "--noproxy", "*", "--silent", "--show-error", "--max-time", "2", "http://203.0.113.8:18080"}
	success := false
	for range 20 {
		raw, e := exec.Command(curl[0], curl[1:]...).Output()
		if e == nil && strings.TrimSpace(string(raw)) == "10.202.0.2" {
			success = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !success {
		t.Fatal("client did not use the NATed home's public exit")
	}
	// Simulate the client's local LAN overlapping the remote home LAN. Native
	// clients install these specific host routes in addition to their defaults.
	ip("-n", "client", "address", "add", "192.168.70.3/24", "dev", "eth0")
	if len(profile.ManagementRoutes) != 1 || profile.ManagementRoutes[0] != "192.168.70.1/32" {
		t.Fatal("management route was not advertised")
	}
	for _, route := range profile.ManagementRoutes {
		ip("-n", "client", "route", "add", route, "dev", "epclient")
	}
	if got := run("", "ip", "netns", "exec", "client", "curl", "--noproxy", "*", "--silent", "--max-time", "3", "http://192.168.70.1:18081"); !strings.HasPrefix(got, "192.168.70.2:") {
		t.Fatal("LAN management did not traverse the home VM", got)
	}
	dns := `import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);s.sendto(bytes.fromhex('1234010000010000000000000376706e04746573740000010001'),('203.0.113.8',53));r=s.recv(512);assert r[-4:]==bytes([203,0,113,8])`
	run("", "ip", "netns", "exec", "client", "python3", "-c", dns)
	exits, err := m.Exits()
	if err != nil || len(exits) != 2 || !exits[1].Ready {
		t.Fatal("home exit readiness", exits, err)
	}
	status, _ := backend.PeerStatus(sitePublic)
	if status.LastHandshake == 0 {
		t.Fatal("outbound home handshake missing")
	}
	// A missing policy rule still cannot use the VPS uplink: the firewall guards it.
	ip("-4", "rule", "del", "priority", fmt.Sprint(18800+m.peers[clientID].Host), "table", homeTable, "protocol", routeProtocol)
	if exec.Command(curl[0], curl[1:]...).Run() == nil {
		t.Fatal("home selection leaked through the VPS after losing its policy rule")
	}
	ip("-4", "rule", "add", "priority", fmt.Sprint(18800+m.peers[clientID].Host), "from", profile.Address, "table", homeTable, "protocol", routeProtocol)
	run("", "ip", "netns", "exec", "router", "iptables", "-I", "FORWARD", "-o", "eth0", "-j", "DROP")
	run("", "ip", "netns", "exec", "router", "iptables", "-I", "FORWARD", "-i", "eth0", "-j", "DROP")
	if exec.Command(curl[0], curl[1:]...).Run() == nil {
		t.Fatal("offline home silently fell back to VPS")
	}
	run("", "ip", "netns", "exec", "router", "iptables", "-D", "FORWARD", "-o", "eth0", "-j", "DROP")
	run("", "ip", "netns", "exec", "router", "iptables", "-D", "FORWARD", "-i", "eth0", "-j", "DROP")
	recovered := false
	for range 20 {
		raw, e := exec.Command(curl[0], curl[1:]...).Output()
		if e == nil && strings.TrimSpace(string(raw)) == "10.202.0.2" {
			recovered = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !recovered {
		for _, args := range [][]string{{"wg", "show"}, {"ip", "netns", "exec", "home", "wg", "show"}, {"ip", "netns", "exec", "home", "ip", "-4", "route"}, {"ip", "netns", "exec", "router", "ip", "-4", "route"}, {"iptables", "-nvL", "FORWARD"}} {
			raw, _ := exec.Command(args[0], args[1:]...).CombinedOutput()
			t.Log(string(raw))
		}
		t.Fatal("home did not recover after link restoration")
	}
	auth[serviceID] = false
	if err = m.reconcile(); err != nil {
		t.Fatal(err)
	}
	if exec.Command(curl[0], curl[1:]...).Run() == nil {
		t.Fatal("revoked home still carried client traffic")
	}
	if err = Cleanup(c); err != nil {
		t.Fatal(err)
	}
	if err = backend.Up(c); err != nil {
		t.Fatal(err)
	}
	restored, err := NewManager(c, dir, backend, func() (map[string]bool, error) { return auth, nil })
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range restored.peers {
		if err = backend.SetPeer(c, p); err != nil {
			t.Fatal(err)
		}
	}
	// Persisted home selection remains closed after a core/helper restart.
	if exec.Command(curl[0], curl[1:]...).Run() == nil {
		t.Fatal("restart silently changed the selected exit")
	}
	if _, err = restored.RegisterExit(clientID, public, "vps"); err != nil {
		t.Fatal(err)
	}
	recovered = false
	for range 20 {
		raw, e := exec.Command(curl[0], curl[1:]...).Output()
		if e == nil && strings.TrimSpace(string(raw)) == "10.201.0.1" {
			recovered = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !recovered {
		t.Fatal("explicit VPS selection failed after helper restart")
	}
	t.Log("real two-leg WireGuard, NAT-only home, home egress, DNS, LAN management, outage, revocation, restart and explicit VPS selection passed")
}
